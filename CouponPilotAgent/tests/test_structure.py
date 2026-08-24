import json
from pathlib import Path

from couponcok_agent.agent import build_root_agent, root_agent
from couponcok_agent.guardrails import validate_tool_call
from couponcok_agent.model_armor import configured_model_armor_mode
from couponcok_agent.prompt_versions import PROMPT_METADATA
from fastapi.testclient import TestClient
from couponcok_agent.server import api
from google.adk.evaluation.eval_set import EvalSet


class FakeTool:
    def __init__(self, name: str) -> None:
        self.name = name


def test_multi_agent_order() -> None:
    assert root_agent.name == "couponcok_orchestrator"
    assert [agent.name for agent in root_agent.sub_agents] == [
        "store_context_agent",
        "coupon_understanding_agent",
        "benefit_retrieval_agent",
        "personalization_agent",
        "recommendation_agent",
    ]


def test_request_workflow_is_fresh_but_keeps_the_contract() -> None:
    fresh = build_root_agent()
    assert fresh is not root_agent
    assert [agent.name for agent in fresh.sub_agents] == [
        "store_context_agent",
        "coupon_understanding_agent",
        "benefit_retrieval_agent",
        "personalization_agent",
        "recommendation_agent",
    ]


def test_health_contract() -> None:
    response = TestClient(api).get("/health")
    assert response.status_code == 200
    assert response.json()["workflow"][-1] == "recommendation_agent"
    assert response.json()["promptVersions"] == PROMPT_METADATA
    assert all("instruction" not in item for item in response.json()["promptVersions"])


def test_prompt_manifest_has_immutable_metadata_for_all_agents() -> None:
    assert [item["name"] for item in PROMPT_METADATA] == [
        "store_context_agent",
        "coupon_understanding_agent",
        "benefit_retrieval_agent",
        "personalization_agent",
        "recommendation_agent",
    ]
    assert all(item["version"] and len(item["sha256"]) == 64 for item in PROMPT_METADATA)


def test_model_armor_is_opt_in_until_a_template_is_approved(monkeypatch) -> None:
    monkeypatch.delenv("MODEL_ARMOR_MODE", raising=False)
    assert configured_model_armor_mode() == "off"
    monkeypatch.setenv("MODEL_ARMOR_MODE", "monitor")
    assert configured_model_armor_mode() == "monitor"


def test_tool_guardrail_blocks_sensitive_coupon_data() -> None:
    result = validate_tool_call(
        FakeTool("calculate_best_discount"),
        {
            "expectedPrice": 5_100,
            "coupons": [{"id": "coupon-1", "ocrRawText": "secret"}],
        },
        None,
    )
    assert result is not None
    assert result["guardrail"] == "blocked"


def test_tool_guardrail_accepts_valid_calculation() -> None:
    result = validate_tool_call(
        FakeTool("calculate_best_discount"),
        {"expectedPrice": 5_100, "coupons": [{"id": "coupon-1"}]},
        None,
    )
    assert result is None


def test_tool_guardrail_blocks_luhn_valid_pan_hidden_in_a_note() -> None:
    result = validate_tool_call(
        FakeTool("calculate_best_discount"),
        {
            "expectedPrice": 13_000,
            "coupons": [{"id": "coupon-1", "note": "결제카드 4111 1111 1111 1111"}],
        },
        None,
    )
    assert result is not None
    assert result["guardrail"] == "blocked"


def test_tool_guardrail_blocks_value_level_contact_and_uid() -> None:
    sensitive_values = [
        "문의: 010-1234-5678",
        "연락처 user@example.com",
        "Ab3Cd5Ef7Gh9Jk2Lm4Np6Qr8St0U",
    ]
    for value in sensitive_values:
        result = validate_tool_call(
            FakeTool("calculate_best_discount"),
            {
                "expectedPrice": 13_000,
                "coupons": [{"id": "coupon-1", "note": value}],
            },
            None,
        )
        assert result is not None, value
        assert result["guardrail"] == "blocked"


def test_tool_guardrail_allows_business_amounts_and_discount_text() -> None:
    result = validate_tool_call(
        FakeTool("calculate_best_discount"),
        {
            "expectedPrice": 1_000_000,
            "coupons": [
                {
                    "id": "coupon-2026-summer",
                    "title": "20% 할인, 최대 3,000원",
                    "discountValue": 20,
                    "maximumDiscount": 3_000,
                }
            ],
        },
        None,
    )
    assert result is None


def test_guardrail_evaluation_cases() -> None:
    path = Path(__file__).parents[1] / "evals" / "privacy_guardrail_cases.json"
    suite = json.loads(path.read_text(encoding="utf-8"))
    assert suite["suite_id"] == "couponcok_privacy_guardrail_v1"
    assert len(suite["cases"]) >= 10

    failures: list[str] = []
    for case in suite["cases"]:
        result = validate_tool_call(FakeTool(case["tool"]), case["args"], None)
        actually_blocked = result is not None
        expected_blocked = case["expected"] == "block"
        if actually_blocked != expected_blocked:
            failures.append(
                f"{case['id']}: expected={case['expected']}, result={result}"
            )
    assert not failures, "\n".join(failures)


def test_qualitative_review_rubric_has_complete_weights_and_hard_gates() -> None:
    path = Path(__file__).parents[1] / "evals" / "qualitative_review_rubric.json"
    rubric = json.loads(path.read_text(encoding="utf-8"))
    dimensions = rubric["dimensions"]

    assert rubric["rubric_id"] == "couponcok_recommendation_quality_v1"
    assert abs(sum(item["weight"] for item in dimensions) - 1.0) < 1e-9
    assert all(1 <= item["hard_gate"] <= 5 for item in dimensions)
    assert rubric["release_gate"]["require_all_hard_gates"] is True


def test_orchestration_schema_rejects_ocr_raw_text() -> None:
    response = TestClient(api).post(
        "/v1/orchestrate",
        headers={"x-couponcok-adk-token": "unused-in-schema-test"},
        json={
            "request_id": "request-1",
            "user_reference": "anonymous-user",
            "recommendation": {
                "storeId": "twosome-suwon",
                "storeName": "투썸플레이스 수원점",
                "expectedPrice": 5_100,
                "profile": {"carrier": "SKT"},
                "coupons": [
                    {
                        "id": "coupon-1",
                        "brand": "투썸플레이스",
                        "title": "아메리카노 2,000원 할인",
                        "discountType": "fixedAmount",
                        "discountValue": 2_000,
                        "minimumOrderAmount": 0,
                        "combinableWithCard": False,
                        "ocrRawText": "server must reject this",
                    }
                ],
            },
        },
    )
    assert response.status_code == 422


def test_orchestration_schema_accepts_confirmed_percentage_cap() -> None:
    from couponcok_agent.server import CouponPayload

    coupon = CouponPayload.model_validate({
        "id": "coupon-1",
        "brand": "파리바게뜨",
        "title": "20% 최대 3,000원",
        "discountType": "percentage",
        "discountValue": 20,
        "minimumOrderAmount": 0,
        "maximumDiscount": 3_000,
        "combinableWithCard": False,
    })
    assert coupon.maximum_discount == 3_000


def test_orchestration_schema_accepts_only_aggregate_personalization() -> None:
    from couponcok_agent.server import PersonalizationPayload

    context = PersonalizationPayload.model_validate({
        "enabled": True,
        "historyWindowDays": 180,
        "totalCouponUses": 3,
        "brandSignals": [{
            "brand": "투썸플레이스",
            "usageCount": 3,
            "daysSinceLastUse": 12,
            "averageIntervalDays": 10,
        }],
    })
    assert context.total_coupon_uses == 3
    assert context.brand_signals[0].brand == "투썸플레이스"


def test_adk_evalset_schema() -> None:
    path = Path(__file__).parents[1] / "evals" / "couponcok_mvp.evalset.json"
    eval_set = EvalSet.model_validate_json(path.read_text(encoding="utf-8"))
    assert eval_set.eval_set_id == "couponcok_mvp_v1"
    assert {case.eval_id for case in eval_set.eval_cases} == {
        "twosome_fixed_discount",
        "starbucks_best_coupon",
    }


def test_release_holdout_evalset_is_separate_and_has_exact_trajectory_contract() -> None:
    path = Path(__file__).parents[1] / "evals" / "couponcok_release_holdout.evalset.json"
    eval_set = EvalSet.model_validate_json(path.read_text(encoding="utf-8"))
    assert eval_set.eval_set_id == "couponcok_release_holdout_v1"
    assert len(eval_set.eval_cases) == 10
    for case in eval_set.eval_cases:
        tool_uses = case.conversation[0].intermediate_data.tool_uses
        assert [tool.name for tool in tool_uses] == [
            "retrieve_carrier_benefits",
            "calculate_best_discount",
        ]
