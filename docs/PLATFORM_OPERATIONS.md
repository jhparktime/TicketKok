# CouponCock platform operations

## Prompt versions

`CouponPilotAgent/prompt_manifest.json` is the immutable release record for the five ADK prompts. It contains only agent name, stable version ID, and SHA-256—not prompt content. Each version ends in the first 12 SHA-256 characters, so startup and `python scripts/check_prompt_versions.py` fail if a prompt hash changes without both a manifest hash and a version update. The ADK health/orchestration response carries the same safe metadata; the backend returns it under `agentRun.promptVersions` when ADK runs. Promotion means evaluate the candidate manifest against the protected holdout, then deploy an immutable ADK image after human approval. Rollback means deploy the prior immutable image/manifest pair; never edit a released manifest in place. Calculator authority is unchanged: it neither reads prompt versions nor accepts agent-computed money/ranking.

## Cloud Trace scope

The Node API and MCP boundary use the OpenTelemetry Node SDK and Google Cloud Trace exporter only when `GOOGLE_CLOUD_TRACE_ENABLED=true`. It is disabled in tests and defaults off locally. Initialization is lazy and fail-open; Cloud Run ADC supplies credentials. Span attributes are filtered to exclude raw coupon/OCR/PAN/UID-like keys. Python ADK AgentOps tracing is a separate service concern and is not exported/configured by the Node provider. Configure the runtime identity with Cloud Trace write permission before enabling; this repository does not claim it has been enabled or exported traces.

The official exporter currently emits an upstream deprecation warning in favor of Google Cloud's OTLP Telemetry API. It is retained here because this release explicitly uses the Google Cloud Trace exporter; schedule an OTLP migration before the upstream archive date and keep the same attribute allowlist.

## Vertex AI Pipelines (offline only)

`pipelines/` defines one parameterized KFP v2 governance graph. `benefit_rag` reads a candidate JSON URI and performs official-domain, rights, lifecycle, schema, and staleness checks before writing quality/report and manual-review artifacts. `adk_release` reads the immutable prompt manifest and backend-test or protected-ADK-evaluation evidence before writing metrics/decision artifacts. Neither component is in the live recommendation path and neither automatically publishes/promotes. Compile with `cd pipelines && python -m couponcok_pipelines.compile --output dist/couponcok-governance-gates.json`. The submit CLI is dry-run by default; use `--candidate-manifest-uri gs://...` for `benefit_rag`, or `--prompt-manifest-uri gs://... --evaluation-evidence-uri gs://... --mode adk_release` for the release gate. Add `--submit` only after providing actual project, region (default `asia-northeast3`), bucket, pipeline root, service account, and the relevant artifact URI. Vertex model location may remain `global`; pipeline location is independently configurable.

External setup still required: enable Vertex AI and Cloud Trace APIs, create a pipeline artifact bucket, give the explicitly chosen pipeline service account Vertex Pipeline/job, bucket, and protected-eval dataset permissions, and configure protected staging inputs. Compilation and tests here do not execute a pipeline or create GCP resources.
