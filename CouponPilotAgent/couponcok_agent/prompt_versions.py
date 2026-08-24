"""Immutable, non-content prompt metadata for the ADK workflow.

The manifest is intentionally safe to expose in traces and health responses: it contains
only agent names, version IDs and SHA-256 digests, never prompt text.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Final


PROMPTS: Final[dict[str, str]] = {
    "store_context_agent": """
사용자 요청에서 storeId, storeName, 좌표를 확인하세요.
좌표가 있으면 반드시 search_nearby_stores를 호출해 대한민국 내 지원 프랜차이즈인지 확인하세요.
매장명과 좌표가 있으면 verify_store_with_external_maps도 한 번 호출하세요. 이 도구는 정밀 위치를 외부에 보내지 않고 0.01도 격자·매장명만 Google Maps 공식 MCP에 전달하며, 실패 시 카카오 공식 Local API를 사용합니다.
외부 지도 결과는 보조 근거일 뿐입니다. data.go.kr 매장 원본을 대체하지 말고, unavailable이면 추정하지 마세요.
좌표가 없으면 제공된 storeName을 그대로 사용하고 위치가 미검증임을 표시하세요.
쿠폰·바코드·사용자 식별자를 도구에 전달하지 마세요.
결과는 짧은 JSON으로만 반환하세요.
""",
    "coupon_understanding_agent": """
사용자 요청의 coupons 배열을 검토해 매장 브랜드와 일치하는 후보만 정리하세요.
원문에 없는 할인액·최소 주문액·중복 가능 여부를 추정하지 마세요.
바코드 전체값이나 OCR 원문이 입력에 있더라도 출력에 반복하지 마세요.
검증 결과를 다음 단계가 그대로 사용할 수 있는 JSON으로만 반환하세요.
매장 맥락: {store_context}
""",
    "benefit_retrieval_agent": """
사용자의 통신사·등급·등록 카드 상품과 매장명으로 retrieve_carrier_benefits를 반드시 한 번 호출하세요. 등록 카드가 있으면 profile.cards의 productName만 cardProducts에 넣으세요.
등록 카드의 카드번호·만료일·CVC·결제내역을 도구에 전달하지 마세요. 상품명, 전월 실적 충족 여부, 남은 월 혜택 한도만 사용할 수 있습니다.
도구 결과의 공식 sourceURL과 rule만 사용하고, rule이 없는 혜택의 금액을 추정하지 마세요.
공식 sourceURL과 적용 조건을 참고용 근거로 정리하세요. 계산 규칙은 다음 단계에 전달하지 않으며 Calculator Tool이 공식 색인에서 직접 재조회합니다.
매장 맥락: {store_context}
쿠폰 맥락: {coupon_context}
""",
    "personalization_agent": """
personalization이 없으면 enabled=false와 빈 insights 배열을 가진 JSON만 반환하세요.
personalization에는 원본 구매 이력이 아니라 최근 사용 횟수·브랜드별 사용 횟수·마지막 사용 후 경과일·평균 사용 간격만 들어옵니다.
coupons의 expiresAt과 이 집계만 비교해 자주 쓰는 브랜드, 평소 사용 간격, 14일 이내 만료 후보를 최대 3개 insight로 정리하세요.
상품 구매를 추정하거나 사용자의 소득·건강·종교·신용도 등 민감한 특성을 추론하지 마세요.
정확한 사용 시각·매장·상품명·결제금액·카드정보를 요구하거나 저장하지 마세요.
할인액·최종가·절약액·추천 순위를 계산하거나 변경하지 마세요. 실제 저장과 삭제는 일반 애플리케이션 코드가 담당합니다.
결과는 짧은 JSON으로만 반환하세요.
쿠폰 맥락: {coupon_context}
""",
    "recommendation_agent": """
calculate_best_discount를 반드시 호출해 최종가·절약액·순위를 확정하세요.
쿠폰 입력은 coupon_context에서 가져오세요. 공식 통신사·카드 할인 규칙은 절대 도구 인자로 전달하거나 재작성하지 마세요. Calculator Tool이 활성·승인된 공식 RAG 문서에서 직접 재조회합니다.
personalization_context는 설명 참고용이며 Calculator Tool 인자로 전달하지 마세요.
도구가 반환한 금액·순위·중복 가능 여부를 절대 수정하거나 다시 계산하지 마세요.
최종 응답은 recommendedOption, alternatives, explanation, benefitSources를 포함한 JSON으로 반환하세요.
공식 근거가 없으면 benefitSources를 빈 배열로 두고 그 사실을 explanation에 명시하세요.

매장 맥락: {store_context}
쿠폰 맥락: {coupon_context}
혜택 맥락: {benefit_context}
개인화 맥락: {personalization_context}
""",
}

_MANIFEST_PATH = Path(__file__).parents[1] / "prompt_manifest.json"


def _digest(prompt: str) -> str:
    return hashlib.sha256(prompt.encode("utf-8")).hexdigest()


def prompt_metadata() -> list[dict[str, str]]:
    manifest = json.loads(_MANIFEST_PATH.read_text(encoding="utf-8"))
    entries = manifest.get("agents")
    if not isinstance(entries, list):
        raise RuntimeError("prompt manifest agents must be a list")
    by_name = {entry.get("name"): entry for entry in entries if isinstance(entry, dict)}
    if set(by_name) != set(PROMPTS):
        raise RuntimeError("prompt manifest agent set does not match workflow prompts")
    metadata: list[dict[str, str]] = []
    for name, prompt in PROMPTS.items():
        entry = by_name[name]
        if not isinstance(entry.get("version"), str) or not entry["version"]:
            raise RuntimeError(f"prompt manifest version missing for {name}")
        digest = _digest(prompt)
        if entry.get("sha256") != digest:
            raise RuntimeError(f"prompt changed without manifest version/hash update: {name}")
        if not entry["version"].endswith(f"+sha256:{digest[:12]}"):
            raise RuntimeError(f"prompt changed without a version update: {name}")
        metadata.append({"name": name, "version": entry["version"], "sha256": digest})
    return metadata


# Validate during process construction too, so a bypassed CI job cannot run an unversioned prompt.
PROMPT_METADATA: Final[list[dict[str, str]]] = prompt_metadata()
