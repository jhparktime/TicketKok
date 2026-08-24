import { createHash, randomUUID } from "node:crypto";
import { GoogleAuth } from "google-auth-library";
import type { RecommendationInput } from "./calculator.js";
import { traceOperation } from "./observability.js";
import { assertAgentPayloadSafe, pseudonymizeSubject } from "./privacy.js";

export type AdkOrchestrationResult = {
  requestId: string;
  resultText: string;
  agentSteps?: Record<string, {
    status: "completed" | "skipped" | "blocked" | "failed";
    reason?: string | null;
    data: Record<string, unknown>;
  }>;
  promptVersions?: Array<{ name: string; version: string; sha256: string }>;
};

export type AdkMode = "off" | "shadow" | "explanation";

const cloudRunAuth = new GoogleAuth();
const idTokenClients = new Map<string, any>();

async function cloudRunClient(endpoint: string) {
  const audience = new URL(endpoint).origin;
  const cached = idTokenClients.get(audience);
  if (cached) return cached;
  const client = await cloudRunAuth.getIdTokenClient(audience);
  idTokenClients.set(audience, client);
  return client;
}

export function configuredAdkMode(): AdkMode {
  const value = process.env.ADK_ORCHESTRATION_MODE;
  return value === "shadow" || value === "explanation" ? value : "off";
}

export function shouldRunAdk(mode: AdkMode, requestId: string) {
  if (mode === "off") return false;
  if (mode === "explanation") return true;
  const configured = Number(process.env.ADK_SHADOW_SAMPLE_RATE ?? 1);
  const rate = Number.isFinite(configured) ? Math.min(1, Math.max(0, configured)) : 1;
  if (rate <= 0) return false;
  if (rate >= 1) return true;
  const bucket = Number.parseInt(createHash("sha256").update(requestId).digest("hex").slice(0, 8), 16) / 0xffff_ffff;
  return bucket < rate;
}

export async function runAdkOrchestration(input: RecommendationInput, uid: string, parentRequestId?: string): Promise<AdkOrchestrationResult> {
  const endpoint = process.env.ADK_ORCHESTRATOR_URL?.replace(/\/$/u, "");
  const token = process.env.ADK_INTERNAL_TOKEN;
  if (!endpoint || !token) throw new Error("ADK orchestrator is not configured");
  const requestId = parentRequestId ?? randomUUID();
  // Build the Agent input from an explicit allowlist. The value-level detector catches secrets
  // hidden inside otherwise allowed strings, such as a barcode pasted into a coupon title.
  const recommendation = {
    storeId: input.storeId,
    storeName: input.storeName,
    expectedPrice: input.expectedPrice,
    profile: {
      carrier: input.profile.carrier,
      membershipGrade: input.profile.membershipGrade,
      monthlyBenefitStatus: input.profile.monthlyBenefitStatus,
      cards: input.profile.cards?.map((card) => ({
        issuer: card.issuer,
        productId: card.productId,
        productName: card.productName,
        previousMonthSpendQualified: card.previousMonthSpendQualified,
        monthlyBenefitRemainingAmount: card.monthlyBenefitRemainingAmount
      }))
    },
    coupons: input.coupons.map((coupon) => ({
      id: coupon.id,
      brand: coupon.brand,
      title: coupon.title,
      discountType: coupon.discountType,
      discountValue: coupon.discountValue,
      minimumOrderAmount: coupon.minimumOrderAmount,
      maximumDiscount: coupon.maximumDiscount,
      expiresAt: coupon.expiresAt,
      combinableWithCard: coupon.combinableWithCard,
      referencePrice: coupon.referencePrice
    })),
    personalization: input.personalization ? {
      enabled: true as const,
      historyWindowDays: input.personalization.historyWindowDays,
      totalCouponUses: input.personalization.totalCouponUses,
      brandSignals: input.personalization.brandSignals.map((signal) => ({
        brand: signal.brand,
        usageCount: signal.usageCount,
        daysSinceLastUse: signal.daysSinceLastUse,
        averageIntervalDays: signal.averageIntervalDays
      }))
    } : undefined
  };
  assertAgentPayloadSafe(recommendation);
  return traceOperation("agent.adk_orchestration", {
    "couponcok.adk_mode": configuredAdkMode(),
    "couponcok.store": input.storeName ?? input.storeId,
    "couponcok.coupon_count": input.coupons.length,
    "couponcok.personalization_enabled": input.personalization?.enabled === true
  }, async () => {
    const client = await cloudRunClient(endpoint);
    const response = await client.request({
      url: `${endpoint}/v1/orchestrate`,
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-couponcok-adk-token": token
      },
      data: {
        request_id: requestId,
        user_reference: pseudonymizeSubject(uid),
        // Whitelist only fields needed by the agent. Unknown request properties such as
        // barcode values or OCR source text must never enter AgentOps prompt traces.
        recommendation
      },
      timeout: Number(process.env.ADK_TIMEOUT_MS ?? 12_000)
    });
    return response.data as AdkOrchestrationResult;
  });
}

export function adkResultMatchesCalculator(resultText: string, expectedSavings: number, expectedFinalPrice: number) {
  const candidate = resultText.replace(/^```(?:json)?\s*|\s*```$/gu, "").trim();
  try {
    const parsed = JSON.parse(candidate) as {
      recommendedOption?: { savings?: unknown; finalPrice?: unknown };
      data?: { recommendedOption?: { savings?: unknown; finalPrice?: unknown } };
    };
    const option = parsed.data?.recommendedOption ?? parsed.recommendedOption;
    return option?.savings === expectedSavings && option?.finalPrice === expectedFinalPrice;
  } catch {
    return false;
  }
}
