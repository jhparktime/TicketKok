"""Internal HTTP boundary for the CouponCock ADK workflow."""

from __future__ import annotations

import json
import os
from secrets import compare_digest
from typing import Literal

from fastapi import FastAPI, Header, HTTPException
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types
from pydantic import BaseModel, ConfigDict, Field

from .agent import build_root_agent, root_agent
from .model_armor import enforce_model_armor
from .prompt_versions import PROMPT_METADATA

APP_NAME = "couponcok_agent"
api = FastAPI(title="CouponCock ADK Orchestrator", version="1.0.0")


class StrictPayload(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class CouponPayload(StrictPayload):
    id: str = Field(min_length=1, max_length=128)
    brand: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=200)
    discount_type: Literal["fixedAmount", "percentage"] = Field(alias="discountType")
    discount_value: int = Field(alias="discountValue", ge=0, le=1_000_000)
    minimum_order_amount: int = Field(alias="minimumOrderAmount", ge=0, le=1_000_000)
    maximum_discount: int | None = Field(default=None, alias="maximumDiscount", ge=0, le=1_000_000)
    expires_at: str | None = Field(default=None, alias="expiresAt", max_length=40)
    combinable_with_card: bool = Field(alias="combinableWithCard")
    reference_price: int | None = Field(default=None, alias="referencePrice", ge=1, le=1_000_000)


class ProfilePayload(StrictPayload):
    carrier: Literal["SKT", "KT", "LG U+", "없음"]
    membership_grade: str | None = Field(default=None, alias="membershipGrade", max_length=50)
    monthly_benefit_status: Literal["available", "used", "unknown"] | None = Field(
        default=None,
        alias="monthlyBenefitStatus",
    )
    cards: list["CardPayload"] = Field(default_factory=list, max_length=10)


class CardPayload(StrictPayload):
    issuer: Literal["신한카드", "KB국민카드", "현대카드"]
    product_id: str = Field(alias="productId", min_length=1, max_length=100)
    product_name: str = Field(alias="productName", min_length=1, max_length=100)
    previous_month_spend_qualified: bool = Field(alias="previousMonthSpendQualified")
    monthly_benefit_remaining_amount: int = Field(
        alias="monthlyBenefitRemainingAmount",
        ge=0,
        le=1_000_000,
    )


ProfilePayload.model_rebuild()


class BrandUsageSignalPayload(StrictPayload):
    brand: str = Field(min_length=1, max_length=100)
    usage_count: int = Field(alias="usageCount", ge=1, le=10_000)
    days_since_last_use: int = Field(alias="daysSinceLastUse", ge=0, le=365)
    average_interval_days: int | None = Field(default=None, alias="averageIntervalDays", ge=0, le=365)


class PersonalizationPayload(StrictPayload):
    enabled: Literal[True]
    history_window_days: int = Field(alias="historyWindowDays", ge=1, le=365)
    total_coupon_uses: int = Field(alias="totalCouponUses", ge=0, le=10_000)
    brand_signals: list[BrandUsageSignalPayload] = Field(alias="brandSignals", max_length=12)


class RecommendationPayload(StrictPayload):
    store_id: str = Field(alias="storeId", min_length=1, max_length=150)
    store_name: str | None = Field(default=None, alias="storeName", max_length=150)
    expected_price: int = Field(alias="expectedPrice", ge=1, le=1_000_000)
    profile: ProfilePayload
    coupons: list[CouponPayload] = Field(min_length=1, max_length=100)
    personalization: PersonalizationPayload | None = None


class OrchestrationRequest(StrictPayload):
    request_id: str = Field(min_length=1, max_length=100)
    user_reference: str = Field(min_length=1, max_length=128)
    recommendation: RecommendationPayload


def _authorize(token: str | None) -> None:
    expected = os.getenv("ADK_INTERNAL_TOKEN", "")
    if not expected or not token or not compare_digest(token, expected):
        raise HTTPException(status_code=401, detail="Internal ADK authentication required")


@api.get("/health")
async def health() -> dict:
    return {
        "ok": True,
        "service": "couponcok-adk",
        "workflow": [agent.name for agent in root_agent.sub_agents],
        "promptVersions": PROMPT_METADATA,
    }


@api.post("/v1/orchestrate")
async def orchestrate(
    request: OrchestrationRequest,
    x_couponcok_adk_token: str | None = Header(default=None),
) -> dict:
    _authorize(x_couponcok_adk_token)
    session_id = request.request_id
    # Recommendation requests are intentionally stateless. A request-scoped memory service
    # prevents one user's coupon/profile context from surviving into a later request.
    request_session_service = InMemorySessionService()
    # A new toolset gets a fresh Cloud Run ID token for this request. The static root_agent is
    # retained only for lightweight health/structure checks; it must not serve long-lived traffic.
    runner = Runner(agent=build_root_agent(), app_name=APP_NAME, session_service=request_session_service)
    await request_session_service.create_session(
        app_name=APP_NAME,
        user_id=request.user_reference,
        session_id=session_id,
    )
    message_text = json.dumps(
        request.recommendation.model_dump(by_alias=True, exclude_none=True),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    try:
        await enforce_model_armor(message_text, "prompt")
    except RuntimeError as error:
        raise HTTPException(status_code=422, detail="Recommendation request blocked by safety policy") from error
    message = types.Content(
        role="user",
        parts=[
            types.Part(text=message_text)
        ],
    )
    final_text = ""
    async for event in runner.run_async(
        user_id=request.user_reference,
        session_id=session_id,
        new_message=message,
    ):
        if event.is_final_response() and event.content and event.content.parts:
            final_text = "\n".join(part.text for part in event.content.parts if part.text)
    if not final_text:
        raise HTTPException(status_code=502, detail="ADK workflow returned no final response")
    try:
        await enforce_model_armor(final_text, "response")
    except RuntimeError as error:
        raise HTTPException(status_code=502, detail="Recommendation response blocked by safety policy") from error
    return {"requestId": request.request_id, "resultText": final_text, "promptVersions": PROMPT_METADATA}
