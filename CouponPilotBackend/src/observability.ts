import { SpanStatusCode, trace, type Attributes } from "@opentelemetry/api";
import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

const tracer = trace.getTracer("couponcok-agent", "1.0.0");
let initialization: Promise<void> | undefined;
let traceExportState: "disabled" | "initializing" | "enabled" | "failed" = "disabled";

export type ObservedRequest = Request & { couponcokRequestId?: string };
export const requestCorrelationID = (req: Request) => (req as ObservedRequest).couponcokRequestId;
export const observabilityStatus = () => ({ cloudTrace: traceExportState, adkTracing: "separate-service" as const });

function cloudTraceRequested() { return process.env.NODE_ENV !== "test" && process.env.GOOGLE_CLOUD_TRACE_ENABLED === "true"; }
// Dynamic load preserves local/test startup and makes exporter initialization fail-open.
const optionalImport = (specifier: string): Promise<any> => new Function("moduleName", "return import(moduleName)")(specifier) as Promise<any>;

/** API/MCP traces only; Python ADK AgentOps remains a separately configured service. */
export function initializeObservability() {
  if (!initialization) initialization = (async () => {
    if (!cloudTraceRequested()) return;
    traceExportState = "initializing";
    try {
      const [{ NodeSDK }, { TraceExporter }, { BatchSpanProcessor }] = await Promise.all([
        optionalImport("@opentelemetry/sdk-node"),
        optionalImport("@google-cloud/opentelemetry-cloud-trace-exporter"),
        optionalImport("@opentelemetry/sdk-trace-base")
      ]);
      const projectId = process.env.GOOGLE_CLOUD_PROJECT || process.env.VERTEX_PROJECT_ID;
      const exporter = new TraceExporter(projectId ? { projectId } : {});
      const sdk = new NodeSDK({
        spanProcessors: [new BatchSpanProcessor(exporter, {
          scheduledDelayMillis: 1_000,
          exportTimeoutMillis: 10_000,
        })],
      });
      await sdk.start();
      traceExportState = "enabled";
      process.once("SIGTERM", () => { void sdk.shutdown(); });
    } catch (error) {
      traceExportState = "failed";
      console.warn(JSON.stringify({ severity: "WARNING", event: "observability.cloud_trace_initialization_skipped", reason: error instanceof Error ? error.name : "unknown" }));
    }
  })();
  return initialization;
}

/** Block raw coupon/OCR/PAN/UID-like keys before any trace exporter receives them. */
export function sanitizeTraceAttributes(attributes: Attributes): Attributes {
  const blocked = /(?:^|\.)(?:coupon(?:_value|_text|_id)?|ocr|pan|uid|user(?:_id)?|email|phone|barcode|card_number)(?:$|\.)/iu;
  return Object.fromEntries(Object.entries(attributes).filter(([key, value]) => !blocked.test(key) && (typeof value === "string" || typeof value === "number" || typeof value === "boolean")));
}

export function recordAIUsage(input: { operation: string; model: string; promptTokens?: number; outputTokens?: number; totalTokens?: number; items?: number; }) {
  if (process.env.NODE_ENV !== "test") console.log(JSON.stringify({ severity: "INFO", event: "finops.ai_usage", ...input }));
}

export function traceHttpRequest(req: Request, res: Response, next: NextFunction) {
  const requestId = randomUUID();
  (req as ObservedRequest).couponcokRequestId = requestId;
  res.setHeader("x-couponcok-request-id", requestId);
  const startedAt = performance.now();
  const span = tracer.startSpan(`${req.method} ${req.path}`, { attributes: sanitizeTraceAttributes({ "http.request.method": req.method, "url.path": req.path, "couponcok.surface": req.path === "/mcp" ? "mcp" : "rest", "couponcok.request_id": requestId }) });
  res.on("finish", () => {
    span.setAttribute("http.response.status_code", res.statusCode);
    span.setAttribute("couponcok.duration_ms", Math.round(performance.now() - startedAt));
    span.setStatus({ code: res.statusCode >= 500 ? SpanStatusCode.ERROR : SpanStatusCode.OK });
    if (process.env.NODE_ENV !== "test") console.log(JSON.stringify({ severity: res.statusCode >= 500 ? "ERROR" : "INFO", event: "http.request", requestId, method: req.method, path: req.path, status: res.statusCode, durationMs: Math.round(performance.now() - startedAt) }));
    span.end();
  });
  next();
}

export async function traceOperation<T>(name: string, attributes: Attributes, operation: () => Promise<T>): Promise<T> {
  const startedAt = performance.now();
  const safe = sanitizeTraceAttributes(attributes);
  return tracer.startActiveSpan(name, { attributes: safe }, async (span) => {
    try {
      const result = await operation();
      span.setStatus({ code: SpanStatusCode.OK });
      if (process.env.NODE_ENV !== "test") console.log(JSON.stringify({ severity: "INFO", event: name, durationMs: Math.round(performance.now() - startedAt), ...safe }));
      return result;
    } catch (error) {
      span.recordException(error instanceof Error ? error : new Error(String(error)));
      span.setStatus({ code: SpanStatusCode.ERROR, message: error instanceof Error ? error.message : "operation failed" });
      if (process.env.NODE_ENV !== "test") console.error(JSON.stringify({ severity: "ERROR", event: name, durationMs: Math.round(performance.now() - startedAt), error: error instanceof Error ? error.message : "operation failed", ...safe }));
      throw error;
    } finally { span.end(); }
  });
}
