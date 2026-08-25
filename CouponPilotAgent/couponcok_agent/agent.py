"""CouponCock ADK multi-agent workflow.

The workflow deliberately keeps all price authority inside the Calculator MCP tool.
Agents may validate, retrieve evidence and explain, but must never invent or alter money.
"""

from __future__ import annotations

import os
from typing import Any, Literal
from urllib.parse import urlparse

from dotenv import load_dotenv
from google.adk.agents import LlmAgent
from google.adk.apps import App
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import (
    StreamableHTTPConnectionParams,
)
from google.auth import default as google_auth_default
from google.auth import impersonated_credentials
from google.auth.exceptions import DefaultCredentialsError
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.genai import types
from google.oauth2 import id_token
from pydantic import BaseModel, ConfigDict, Field

from google.adk.workflow import JoinNode, Workflow, node

from .guardrails import validate_tool_call
from .prompt_versions import PROMPTS

load_dotenv()

# AgentOps must be initialized before ADK agent instances are constructed so it can
# automatically observe agent, model and MCP tool spans. Observability is optional:
# a missing key or exporter outage must never block the recommendation path.
if os.getenv("AGENTOPS_API_KEY"):
    import agentops

    try:
        agentops.init()
    except Exception as error:
        print(f"AgentOps initialization skipped: {type(error).__name__}")

MODEL = os.getenv("ADK_MODEL", "gemini-2.5-flash")
MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "http://127.0.0.1:8081/mcp")
MCP_INTERNAL_TOKEN = os.getenv("MCP_INTERNAL_TOKEN", "")
MCP_IAM_SERVICE_ACCOUNT = os.getenv("MCP_IAM_SERVICE_ACCOUNT", "")


class AgentStepResult(BaseModel):
    """A machine-readable handoff contract for every non-pricing Agent.

    `skipped` is an intentional, successful no-op: downstream Agents must not
    wait for a coupon or benefit that cannot exist for this request. `blocked`
    means the app needs more user input; `failed` means an operational failure.
    Price authority is deliberately excluded from this contract.
    """

    model_config = ConfigDict(extra="forbid")

    status: Literal["completed", "skipped", "blocked", "failed"]
    reason: str | None = Field(default=None, max_length=240)
    data: dict[str, Any] = Field(default_factory=dict)


WORKFLOW_STAGES = [
    ["store_context_agent", "personalization_agent"],
    ["coupon_understanding_agent", "benefit_retrieval_agent"],
    ["recommendation_agent"],
]

STEP_OUTPUT_KEYS = {
    "store_context_agent": "store_context",
    "coupon_understanding_agent": "coupon_context",
    "benefit_retrieval_agent": "benefit_context",
    "personalization_agent": "personalization_context",
    "recommendation_agent": "recommendation_result",
}


def _generation_config(max_output_tokens: int) -> types.GenerateContentConfig:
    """Keep JSON agents deterministic and cap token cost for the short workflow."""

    return types.GenerateContentConfig(
        temperature=0,
        max_output_tokens=max_output_tokens,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )


def _cloud_run_id_token(audience: str) -> str:
    """Issue a Cloud Run ID token for both runtime and GitHub WIF callers."""

    try:
        return id_token.fetch_id_token(GoogleAuthRequest(), audience)
    except DefaultCredentialsError:
        # GitHub's WIF credentials are an external-account credential, not a
        # local key or metadata-server identity.  It must impersonate the
        # explicitly configured evaluation service account to mint an ID token.
        if not MCP_IAM_SERVICE_ACCOUNT:
            raise
        source_credentials, _ = google_auth_default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        impersonated = impersonated_credentials.Credentials(
            source_credentials=source_credentials,
            target_principal=MCP_IAM_SERVICE_ACCOUNT,
            target_scopes=["https://www.googleapis.com/auth/cloud-platform"],
            lifetime=3600,
        )
        target_credentials = impersonated_credentials.IDTokenCredentials(
            target_credentials=impersonated,
            target_audience=audience,
            include_email=True,
        )
        target_credentials.refresh(GoogleAuthRequest())
        if not target_credentials.token:
            raise RuntimeError("failed to mint Cloud Run ID token for MCP evaluation")
        return target_credentials.token


def _mcp_toolset(*tool_names: str) -> McpToolset:
    headers = {}
    if MCP_INTERNAL_TOKEN:
        headers["x-couponcok-mcp-token"] = MCP_INTERNAL_TOKEN
    if MCP_SERVER_URL.startswith("https://"):
        parsed = urlparse(MCP_SERVER_URL)
        audience = f"{parsed.scheme}://{parsed.netloc}"
        headers["Authorization"] = f"Bearer {_cloud_run_id_token(audience)}"
    return McpToolset(
        connection_params=StreamableHTTPConnectionParams(
            url=MCP_SERVER_URL,
            headers=headers,
            timeout=20,
            sse_read_timeout=60,
        ),
        tool_filter=list(tool_names),
    )


def build_root_agent() -> Workflow:
    """Create a dependency-aware workflow for one orchestration request.

    Cloud Run ID tokens have a finite lifetime. Creating toolsets at request time ensures an
    MCP call always carries a fresh service-account token instead of an expired startup token.

    The graph intentionally has two fan-out stages. Store context and aggregate-only
    personalization are independent. Once store context is ready, coupon candidate
    selection and official-benefit retrieval can proceed concurrently. A JoinNode prevents
    Calculator-backed recommendation from running before both results are available.
    """

    store_context_agent = LlmAgent(
        name="store_context_agent",
        model=MODEL,
        description="전국 매장 진입 좌표와 매장 브랜드를 확인하는 전문 에이전트",
        instruction=PROMPTS["store_context_agent"],
        tools=[_mcp_toolset("search_nearby_stores", "verify_store_with_external_maps")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(500),
        output_schema=AgentStepResult,
        output_key="store_context",
    )

    coupon_understanding_agent = LlmAgent(
        name="coupon_understanding_agent",
        model=MODEL,
        description="등록된 쿠폰의 브랜드·할인 조건을 검증하는 전문 에이전트",
        instruction=PROMPTS["coupon_understanding_agent"],
        generate_content_config=_generation_config(700),
        output_schema=AgentStepResult,
        output_key="coupon_context",
    )

    benefit_retrieval_agent = LlmAgent(
        name="benefit_retrieval_agent",
        model=MODEL,
        description="공식 통신사·카드 혜택 문서의 근거와 계산 규칙을 검색하는 전문 에이전트",
        instruction=PROMPTS["benefit_retrieval_agent"],
        tools=[_mcp_toolset("retrieve_carrier_benefits")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(700),
        output_schema=AgentStepResult,
        output_key="benefit_context",
    )

    personalization_agent = LlmAgent(
        name="personalization_agent",
        model=MODEL,
        description="동의된 쿠폰 사용 이력 집계를 해석해 만료 위험과 방문 주기를 설명하는 전문 에이전트",
        instruction=PROMPTS["personalization_agent"],
        generate_content_config=_generation_config(600),
        output_schema=AgentStepResult,
        output_key="personalization_context",
    )

    recommendation_agent = LlmAgent(
        name="recommendation_agent",
        model=MODEL,
        description="결정론적 계산 결과를 보존해 최종 추천을 설명하는 전문 에이전트",
        instruction=PROMPTS["recommendation_agent"],
        tools=[_mcp_toolset("calculate_best_discount")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(900),
        output_schema=AgentStepResult,
        output_key="recommendation_result",
    )

    store_node = node(store_context_agent)
    personalization_node = node(personalization_agent)
    coupon_node = node(coupon_understanding_agent)
    benefit_node = node(benefit_retrieval_agent)
    recommendation_node = node(recommendation_agent)
    first_join = JoinNode(name="store_personalization_join")
    second_join = JoinNode(name="coupon_benefit_join")

    return Workflow(
        name="couponcok_orchestrator",
        description="의존성이 있는 단계만 순서대로 실행하고, 독립 Agent는 병렬 실행하는 쿠폰콕 오케스트레이터",
        max_concurrency=2,
        edges=[
            ("START", (store_node, personalization_node)),
            (store_node, first_join),
            (personalization_node, first_join),
            (first_join, (coupon_node, benefit_node)),
            (coupon_node, second_join),
            (benefit_node, second_join),
            (second_join, recommendation_node),
        ],
    )


# Used by health checks and architecture tests. Requests construct their own fresh instance.
root_agent = build_root_agent()

app = App(root_agent=root_agent, name="couponcok_agent")
