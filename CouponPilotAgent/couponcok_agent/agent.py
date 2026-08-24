"""CouponCock ADK multi-agent workflow.

The workflow deliberately keeps all price authority inside the Calculator MCP tool.
Agents may validate, retrieve evidence and explain, but must never invent or alter money.
"""

from __future__ import annotations

import os
from urllib.parse import urlparse

from dotenv import load_dotenv
from google.adk.agents import LlmAgent, SequentialAgent
from google.adk.apps import App
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import (
    StreamableHTTPConnectionParams,
)
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.genai import types
from google.oauth2 import id_token

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


def _generation_config(max_output_tokens: int) -> types.GenerateContentConfig:
    """Keep JSON agents deterministic and cap token cost for the short workflow."""

    return types.GenerateContentConfig(
        temperature=0,
        max_output_tokens=max_output_tokens,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )


def _mcp_toolset(*tool_names: str) -> McpToolset:
    headers = {}
    if MCP_INTERNAL_TOKEN:
        headers["x-couponcok-mcp-token"] = MCP_INTERNAL_TOKEN
    if MCP_SERVER_URL.startswith("https://"):
        parsed = urlparse(MCP_SERVER_URL)
        audience = f"{parsed.scheme}://{parsed.netloc}"
        headers["Authorization"] = f"Bearer {id_token.fetch_id_token(GoogleAuthRequest(), audience)}"
    return McpToolset(
        connection_params=StreamableHTTPConnectionParams(
            url=MCP_SERVER_URL,
            headers=headers,
            timeout=20,
            sse_read_timeout=60,
        ),
        tool_filter=list(tool_names),
    )


def build_root_agent() -> SequentialAgent:
    """Create a workflow for one orchestration request.

    Cloud Run ID tokens have a finite lifetime. Creating toolsets at request time ensures an
    MCP call always carries a fresh service-account token instead of an expired startup token.
    """

    store_context_agent = LlmAgent(
        name="store_context_agent",
        model=MODEL,
        description="전국 매장 진입 좌표와 매장 브랜드를 확인하는 전문 에이전트",
        instruction=PROMPTS["store_context_agent"],
        tools=[_mcp_toolset("search_nearby_stores", "verify_store_with_external_maps")],
        before_tool_callback=validate_tool_call,
        generate_content_config=_generation_config(500),
        output_key="store_context",
    )

    coupon_understanding_agent = LlmAgent(
        name="coupon_understanding_agent",
        model=MODEL,
        description="등록된 쿠폰의 브랜드·할인 조건을 검증하는 전문 에이전트",
        instruction=PROMPTS["coupon_understanding_agent"],
        generate_content_config=_generation_config(700),
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
        output_key="benefit_context",
    )

    personalization_agent = LlmAgent(
        name="personalization_agent",
        model=MODEL,
        description="동의된 쿠폰 사용 이력 집계를 해석해 만료 위험과 방문 주기를 설명하는 전문 에이전트",
        instruction=PROMPTS["personalization_agent"],
        generate_content_config=_generation_config(600),
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
        output_key="recommendation_result",
    )

    return SequentialAgent(
        name="couponcok_orchestrator",
        description="매장 맥락, 쿠폰 후보, 공식 혜택, 결정론적 계산을 순서대로 실행하는 쿠폰콕 오케스트레이터",
        sub_agents=[
            store_context_agent,
            coupon_understanding_agent,
            benefit_retrieval_agent,
            personalization_agent,
            recommendation_agent,
        ],
    )


# Used by health checks and architecture tests. Requests construct their own fresh instance.
root_agent = build_root_agent()

app = App(root_agent=root_agent, name="couponcok_agent")
