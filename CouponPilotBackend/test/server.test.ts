import assert from "node:assert/strict";
import { once } from "node:events";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { calculateOptions, matchingBenefitRules } from "../src/calculator.js";
import { adkResultMatchesCalculator, shouldRunAdk } from "../src/adkClient.js";
import { validateBenefitDocument } from "../src/benefitRag.js";
import { assertAgentPayloadSafe, findSensitiveValue, pseudonymizeSubject, redactSensitiveText } from "../src/privacy.js";
import { app, buildPersonalizationInsight, buildPersonalizedOptions, cardRecognitionInputIsSafe, isWithinKorea } from "../src/server.js";
import { createMcpApp } from "../src/mcpServer.js";
import { sanitizeTraceAttributes } from "../src/observability.js";

const server = app.listen(0, "127.0.0.1");
await once(server, "listening");
const address = server.address();
assert(address && typeof address !== "string");
const baseURL = `http://127.0.0.1:${address.port}`;

try {
  assert.deepEqual(sanitizeTraceAttributes({ "couponcok.coupon_count": 2, "couponcok.ocr": "raw OCR", "couponcok.uid": "firebase-user", "couponcok.pan": "4111111111111111" }), { "couponcok.coupon_count": 2 });
  assert.equal(isWithinKorea(37.5665, 126.978), true, "Seoul coordinates must be accepted by the nationwide store boundary");
  assert.equal(isWithinKorea(33.4996, 126.5312), true, "Jeju coordinates must be accepted by the nationwide store boundary");
  assert.equal(isWithinKorea(35.6762, 139.6503), false, "non-Korean coordinates must stay outside the public-data boundary");
  const governedBenefit = {
    id: "skt-reviewed-benefit",
    title: "검토된 SKT 공식 혜택",
    provider: "SKT",
    sourceURL: "https://sktmembership.tworld.co.kr/official",
    content: "공식 혜택 조건 원문을 사실 중심으로 구조화한 검토 문서입니다. 적용 대상과 기간, 할인 한도, 제외 조건 및 실제 공식 앱에서 최종 확인해야 하는 제한사항을 함께 기록합니다.",
    governance: {
      status: "active" as const,
      checkedAt: "2026-08-20",
      staleAfter: "2026-09-20",
      version: "2026-08-20.v1",
      reviewer: "박재현",
      license: "Official-link citation and factual paraphrase reviewed",
      limitations: ["실제 적용은 공식 앱에서 최종 확인"]
    }
  };
  assert.equal(validateBenefitDocument(governedBenefit), governedBenefit);
  assert.throws(
    () => validateBenefitDocument({ ...governedBenefit, sourceURL: "https://benefit.example.com/skt" }),
    /official-domain allowlist/u,
    "비공식 도메인 문서는 RAG 색인에 들어가면 안 됩니다"
  );
  assert.throws(
    () => validateBenefitDocument({
      ...governedBenefit,
      id: "skt-unscoped-calculator-rule",
      rule: { provider: "SKT", appliesTo: "carrier", discountPercent: 10 }
    }),
    /eligibleStoreKeywords/u,
    "적용 매장이 명시되지 않은 규칙은 모든 매장에 확장되면 안 됩니다"
  );
  assert.throws(
    () => validateBenefitDocument({
      ...governedBenefit,
      id: "skt-unknown-rights",
      governance: { ...governedBenefit.governance, license: "unknown" }
    }),
    /reviewed license/u,
    "권리 검토가 끝나지 않은 문서는 운영 색인에 들어가면 안 됩니다"
  );
  process.env.ADK_SHADOW_SAMPLE_RATE = "0";
  assert.equal(shouldRunAdk("shadow", "stable-request-id"), false);
  process.env.ADK_SHADOW_SAMPLE_RATE = "1";
  assert.equal(shouldRunAdk("shadow", "stable-request-id"), true);
  assert.equal(shouldRunAdk("explanation", "stable-request-id"), true);
  delete process.env.ADK_SHADOW_SAMPLE_RATE;

  const pseudonym = pseudonymizeSubject("firebase-user-123", "a-secure-environment-specific-pseudonym-key");
  assert.match(pseudonym, /^[0-9a-f]{32}$/u);
  assert.doesNotMatch(pseudonym, /firebase-user-123/u);
  assert.equal(
    pseudonymizeSubject("firebase-user-123", "a-secure-environment-specific-pseudonym-key"),
    pseudonym,
    "the same subject and environment key must be stable for request correlation"
  );
  assert.notEqual(
    pseudonymizeSubject("firebase-user-123", "a-different-environment-pseudonym-key"),
    pseudonym,
    "different environments must not share a linkable pseudonym"
  );
  assert.equal(findSensitiveValue({ title: "음료 3,000원 할인", product: "KB 톡톡 Pay" }), undefined);
  assert.equal(findSensitiveValue({ title: "문의 user@example.com" })?.kind, "email");
  assert.equal(findSensitiveValue({ title: "연락처 010-1234-5678" })?.kind, "phone");
  assert.equal(findSensitiveValue({ title: "4111 1111 1111 1111" })?.kind, "card-number");
  assert.equal(findSensitiveValue({ title: "쿠폰 1234-5678-9012-3456" })?.kind, "long-digit-secret");
  assert.throws(
    () => assertAgentPayloadSafe({ coupons: [{ title: "쿠폰번호 123456789012" }] }),
    /long-digit-secret/u
  );
  const redactedOCR = redactSensitiveText("스타벅스 아메리카노 쿠폰 1234-5678-9012-3456 문의 user@example.com");
  assert.equal(redactedOCR.text.includes("1234-5678-9012-3456"), false);
  assert.equal(redactedOCR.text.includes("user@example.com"), false);
  assert.match(redactedOCR.text, /스타벅스 아메리카노/u);

  const safeCardVisualSignature = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64)]).toString("base64");
  assert.equal(
    cardRecognitionInputIsSafe({
      frontText: "신한카드 Mr.Life [민감정보 제거]",
      backText: "상품명 확인용 문구",
      frontVisualSignatureBase64: safeCardVisualSignature
    }),
    true,
    "card classifier accepts only device-sanitized secret-free text"
  );
  assert.equal(
    cardRecognitionInputIsSafe({
      frontText: "신한카드 4111 1111 1111 1111",
      backText: "",
      frontVisualSignatureBase64: safeCardVisualSignature
    }),
    false,
    "PAN-like text must be rejected before Gemini is called"
  );
  assert.equal(
    cardRecognitionInputIsSafe({
      frontText: "신한카드",
      backText: "CVV 123",
      frontVisualSignatureBase64: safeCardVisualSignature
    }),
    false,
    "CVC labels must be rejected even when the number is short"
  );
  const cardImageInput = await fetch(`${baseURL}/v1/cards/recognize`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      frontText: "신한카드 Mr.Life",
      backText: "",
      originalFrontImageBase64: "not-allowed",
      userApprovedCloudAnalysis: true
    })
  });
  assert.equal(cardImageInput.status, 400, "card recognition must reject original-image fields and accept only an iOS-redacted visual signature");

  const health = await fetch(`${baseURL}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true, service: "couponcok-api", observability: { cloudTrace: "disabled", adkTracing: "separate-service" } });
  assert.match(health.headers.get("x-couponcok-request-id") ?? "", /^[0-9a-f-]{36}$/u);

  const readiness = await fetch(`${baseURL}/ready`);
  assert.equal(readiness.status, 503, "a local test process must not claim production dependency readiness");
  const readinessBody = await readiness.json() as { checks: Record<string, boolean> };
  assert.equal(typeof readinessBody.checks.dataGo, "boolean");

  const response = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "suwon-demo-starbucks", expectedPrice: 15_000,
      profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
      coupons: [
        { id: "coupon-001", brand: "스타벅스", title: "음료 3,000원 할인", discountType: "fixedAmount", discountValue: 3_000, minimumOrderAmount: 10_000, combinableWithCard: true },
        { id: "coupon-002", brand: "스타벅스", title: "제조 음료 20% 할인", discountType: "percentage", discountValue: 20, minimumOrderAmount: 0, combinableWithCard: false }
      ]
    })
  });
  assert.equal(response.status, 200);
  const recommendation = await response.json() as { explanation: string; recommendedOption: { finalPrice: number; savings: number } };
  // Without an ingested official benefit rule, only the deterministic coupon calculator applies.
  assert.equal(recommendation.recommendedOption.finalPrice, 12_000);
  assert.equal(recommendation.recommendedOption.savings, 3_000);
  assert.match(recommendation.explanation, /최종가는 12,000원이며 3,000원 절약/u);

  const personalizationInsight = buildPersonalizationInsight({
    storeId: "twosome-seoul",
    storeName: "투썸플레이스 강남점",
    expectedPrice: 5_100,
    profile: { carrier: "없음" },
    coupons: [
      { id: "best", brand: "투썸플레이스", title: "2,000원 할인", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-09-30T00:00:00.000Z" },
      { id: "urgent", brand: "파리바게뜨", title: "20% 할인", discountType: "percentage", discountValue: 20, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-08-30T00:00:00.000Z" }
    ],
    personalization: {
      enabled: true,
      historyWindowDays: 180,
      totalCouponUses: 4,
      brandSignals: [{ brand: "투썸플레이스", usageCount: 4, daysSinceLastUse: 12, averageIntervalDays: 10 }]
    }
  }, "best", new Date("2026-08-24T00:00:00.000Z"));
  assert.match(personalizationInsight ?? "", /4회 사용/u);
  assert.match(personalizationInsight ?? "", /6일 안에 만료/u);
  assert.match(personalizationInsight ?? "", /할인 금액은 Calculator가 확정/u);

  const personalized = buildPersonalizedOptions({
    storeId: "twosome-seoul",
    storeName: "투썸플레이스 강남점",
    expectedPrice: 10_000,
    profile: { carrier: "없음" },
    coupons: [
      { id: "price-leader", brand: "투썸플레이스", title: "3,000원 할인", discountType: "fixedAmount", discountValue: 3_000, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-10-01T00:00:00.000Z" },
      { id: "expires-soon", brand: "투썸플레이스", title: "2,500원 할인", discountType: "fixedAmount", discountValue: 2_500, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-08-30T00:00:00.000Z" }
    ],
    personalization: {
      enabled: true,
      historyWindowDays: 180,
      totalCouponUses: 4,
      brandSignals: [{ brand: "투썸플레이스", usageCount: 4, daysSinceLastUse: 12, averageIntervalDays: 10 }]
    }
  }, [
    { id: "price-leader", title: "3,000원 할인", originalPrice: 10_000, finalPrice: 7_000, savings: 3_000, badges: ["쿠폰"] },
    { id: "expires-soon", title: "2,500원 할인", originalPrice: 10_000, finalPrice: 7_500, savings: 2_500, badges: ["쿠폰"] }
  ], new Date("2026-08-24T00:00:00.000Z"));
  assert.equal(personalized?.priceLeader.id, "price-leader", "Calculator price leader remains independently visible");
  assert.equal(personalized?.orderedOptions[0].id, "expires-soon", "expiry evidence can change only the displayed recommendation priority");
  assert.equal(personalized?.ranking?.extraCostComparedToPriceLeader, 500);
  assert.equal(personalized?.ranking?.maxExtraCostAllowed, 1_000);
  assert.equal(personalized?.ranking?.rankChanged, true);

  const excessiveCostPersonalization = buildPersonalizedOptions({
    storeId: "twosome-seoul",
    storeName: "투썸플레이스 강남점",
    expectedPrice: 10_000,
    profile: { carrier: "없음" },
    coupons: [
      { id: "price-leader", brand: "투썸플레이스", title: "5,000원 할인", discountType: "fixedAmount", discountValue: 5_000, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-10-01T00:00:00.000Z" },
      { id: "today-expiry", brand: "투썸플레이스", title: "2,000원 할인", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-08-24T23:59:59.000Z" }
    ],
    personalization: {
      enabled: true,
      historyWindowDays: 180,
      totalCouponUses: 4,
      brandSignals: [{ brand: "투썸플레이스", usageCount: 4, daysSinceLastUse: 12, averageIntervalDays: 10 }]
    }
  }, [
    { id: "price-leader", title: "5,000원 할인", originalPrice: 10_000, finalPrice: 5_000, savings: 5_000, badges: ["쿠폰"] },
    { id: "today-expiry", title: "2,000원 할인", originalPrice: 10_000, finalPrice: 8_000, savings: 2_000, badges: ["쿠폰"] }
  ], new Date("2026-08-24T00:00:00.000Z"));
  assert.equal(excessiveCostPersonalization?.orderedOptions[0].id, "price-leader", "personalization must not override the price leader above the cost guardrail");
  assert.equal(excessiveCostPersonalization?.ranking?.rankChanged, false);

  const expiryRecommendationInsight = buildPersonalizationInsight({
    storeId: "twosome-seoul",
    expectedPrice: 10_000,
    profile: { carrier: "없음" },
    coupons: [{ id: "today-expiry", brand: "투썸플레이스", title: "오늘 만료 2,500원 할인", discountType: "fixedAmount", discountValue: 2_500, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2026-08-24T23:59:59.000Z" }],
    personalization: { enabled: true, historyWindowDays: 180, totalCouponUses: 1, brandSignals: [] }
  }, "today-expiry", new Date("2026-08-24T00:00:00.000Z"));
  assert.match(expiryRecommendationInsight ?? "", /오늘 만료/u, "the selected expiry candidate must explain its own expiry risk");

  const rawPurchaseHistory = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "twosome-seoul", storeName: "투썸플레이스 강남점", expectedPrice: 5_100,
      profile: { carrier: "없음" },
      coupons: [{ id: "best", brand: "투썸플레이스", title: "2,000원 할인", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 0, combinableWithCard: false }],
      personalization: {
        enabled: true, historyWindowDays: 180, totalCouponUses: 1, brandSignals: [],
        purchaseEvents: [{ storeName: "민감한 원본", paidAmount: 5_100, usedAt: "2026-08-24T10:00:00Z" }]
      }
    })
  });
  assert.equal(rawPurchaseHistory.status, 400, "raw purchase events must never enter the Agent request contract");

  const percentageCap = calculateOptions({
    storeId: "paris-suwon", storeName: "파리바게뜨 수원점", expectedPrice: 30_000,
    profile: { carrier: "없음" },
    coupons: [{ id: "pb-cap", brand: "파리바게뜨", title: "20% 최대 3천원", discountType: "percentage", discountValue: 20, maximumDiscount: 3_000, minimumOrderAmount: 0, combinableWithCard: false }]
  }, []);
  assert.equal(percentageCap[0].savings, 3_000);

  assert.equal(
    adkResultMatchesCalculator(JSON.stringify({
      recommendedOption: { savings: 3_000, finalPrice: 12_000 },
      explanation: "계산기 결과를 기준으로 3,000원 절약해 최종 12,000원입니다."
    }), 3_000, 12_000),
    true
  );
  assert.equal(
    adkResultMatchesCalculator(JSON.stringify({
      status: "completed",
      data: { recommendedOption: { savings: 3_000, finalPrice: 12_000 } }
    }), 3_000, 12_000),
    true,
    "상태 계약으로 감싼 ADK 결과도 Calculator 결과를 그대로 보존해야 합니다"
  );
  assert.equal(
    adkResultMatchesCalculator(JSON.stringify({
      recommendedOption: { savings: 9_999, finalPrice: 5_001 },
      explanation: "AI가 금액을 바꾼 잘못된 설명입니다."
    }), 3_000, 12_000),
    false,
    "ADK 설명은 Calculator의 절약액과 최종가를 변경할 수 없어야 합니다"
  );

  const expiredOptions = calculateOptions({
    storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 5_100,
    profile: { carrier: "없음" },
    coupons: [{ id: "expired", brand: "투썸플레이스", title: "만료 쿠폰", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 0, combinableWithCard: false, expiresAt: "2020-01-01T00:00:00.000Z" }]
  }, []);
  assert.equal(expiredOptions.length, 0);

  const oversizedRequest = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 5_100,
      profile: { carrier: "SKT" },
      coupons: Array.from({ length: 101 }, (_, index) => ({
        id: `coupon-${index}`, brand: "투썸플레이스", title: "테스트 쿠폰",
        discountType: "fixedAmount", discountValue: 100, minimumOrderAmount: 0,
        combinableWithCard: false
      }))
    })
  });
  assert.equal(oversizedRequest.status, 400, "API must reject coupon arrays that can amplify Agent cost");

  const singleItemCoupon = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 15_000,
      profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
      coupons: [{ id: "twosome-americano", brand: "투썸플레이스", title: "아메리카노 2,000원 할인", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 5_000, combinableWithCard: true, referencePrice: 5_100 }]
    })
  });
  assert.equal(singleItemCoupon.status, 200);
  const singleItemRecommendation = await singleItemCoupon.json() as { originalPrice: number; recommendedOption: { finalPrice: number; savings: number } };
  assert.equal(singleItemRecommendation.originalPrice, 5_100);
  assert.equal(singleItemRecommendation.recommendedOption.finalPrice, 3_100);
  assert.equal(singleItemRecommendation.recommendedOption.savings, 2_000);

  const cardProfile = {
    carrier: "없음",
    cards: [{
      issuer: "신한카드" as const,
      productId: "shinhancard-mr-life",
      productName: "신한카드 Mr.Life",
      previousMonthSpendQualified: true,
      monthlyBenefitRemainingAmount: 8_000
    }]
  };
  const cardRules = matchingBenefitRules(cardProfile, "투썸플레이스 수원점", [{
    id: "mr-life-1", documentId: "mr-life", title: "신한카드 Mr.Life TIME 할인", provider: "신한카드 Mr.Life",
    sourceURL: "https://www.shinhancard.com/official", text: "공식 조건", embedding: [],
    rule: {
      provider: "신한카드 Mr.Life", appliesTo: "card", cardProductId: "shinhancard-mr-life",
      discountPercent: 10, maximumDiscount: 1_000, combinableWithCoupon: false,
      requiresPreviousMonthSpend: true, eligibleHoursKST: [22]
    }
  }], 22);
  assert.equal(cardRules.length, 1);
  const cardOptions = calculateOptions({
    storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 5_100,
    profile: cardProfile,
    coupons: [{ id: "small-coupon", brand: "투썸플레이스", title: "500원 할인", discountType: "fixedAmount", discountValue: 500, minimumOrderAmount: 0, combinableWithCard: false }]
  }, cardRules);
  assert.equal(cardOptions[0].title, "신한카드 Mr.Life 공식 혜택");
  assert.equal(cardOptions[0].finalPrice, 4_590);
  assert.deepEqual(cardOptions[0].badges, ["카드 공식혜택"]);

  const overDiscountedCoupon = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 5_100,
      profile: { carrier: "SKT" },
      coupons: [{ id: "too-large", brand: "투썸플레이스", title: "과대 할인 입력", discountType: "fixedAmount", discountValue: 20_000, minimumOrderAmount: 0, combinableWithCard: false }]
    })
  });
  assert.equal(overDiscountedCoupon.status, 200);
  const cappedRecommendation = await overDiscountedCoupon.json() as { recommendedOption: { finalPrice: number; savings: number } };
  assert.equal(cappedRecommendation.recommendedOption.finalPrice, 0);
  assert.equal(cappedRecommendation.recommendedOption.savings, 5_100);

  // Shadow Agent failure is an observability event, never a customer-facing pricing outage.
  process.env.ADK_ORCHESTRATION_MODE = "shadow";
  process.env.ADK_SHADOW_SAMPLE_RATE = "1";
  delete process.env.ADK_ORCHESTRATOR_URL;
  delete process.env.ADK_INTERNAL_TOKEN;
  const shadowFallback = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "twosome-suwon", storeName: "투썸플레이스 수원점", expectedPrice: 5_100,
      profile: { carrier: "SKT" },
      coupons: [{ id: "shadow-coupon", brand: "투썸플레이스", title: "2,000원 할인", discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 0, combinableWithCard: false }]
    })
  });
  assert.equal(shadowFallback.status, 200);
  const shadowResponse = await shadowFallback.json() as { agentRun: { mode: string; status: string }; recommendedOption: { finalPrice: number } };
  assert.deepEqual(shadowResponse.agentRun, { mode: "shadow", status: "failed" });
  assert.equal(shadowResponse.recommendedOption.finalPrice, 3_100);
  process.env.ADK_ORCHESTRATION_MODE = "off";
  delete process.env.ADK_SHADOW_SAMPLE_RATE;

  // CouponPilot is not a generic coupon wallet: a coupon is considered only after
  // the entered store's franchise has matched it.
  const mismatchedCoupon = await fetch(`${baseURL}/v1/recommendations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      storeId: "suwon-demo-starbucks", storeName: "스타벅스 수원시청점", expectedPrice: 15_000,
      profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
      coupons: [{ id: "gongcha-only", brand: "공차", title: "공차 전용 할인", discountType: "fixedAmount", discountValue: 3_000, minimumOrderAmount: 0, combinableWithCard: false }]
    })
  });
  assert.equal(mismatchedCoupon.status, 422);

  const supportedFranchises = [
    ["스타벅스", "스타벅스 수원시청점"], ["투썸플레이스", "투썸플레이스 수원점"],
    ["메가MGC커피", "메가커피 수원점"], ["이디야", "이디야커피 수원점"],
    ["컴포즈커피", "컴포즈커피 수원점"], ["빽다방", "빽다방 수원점"],
    ["할리스", "할리스커피 수원점"], ["커피빈", "커피빈 수원점"],
    ["공차", "공차 수원점"], ["더벤티", "더벤티 수원점"],
    ["베스킨라빈스", "베스킨라빈스 수원점"], ["파리바게뜨", "파리바게뜨 수원점"],
    ["뚜레쥬르", "뚜레쥬르 수원점"], ["애슐리 퀸즈", "애슐리 퀸즈 수원점"]
  ];
  for (const [brand, storeName] of supportedFranchises) {
    const match = await fetch(`${baseURL}/v1/recommendations`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({
        storeId: storeName, storeName, expectedPrice: 10_000,
        profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
        coupons: [{ id: brand, brand, title: `${brand} 테스트 쿠폰`, discountType: "fixedAmount", discountValue: 1_000, minimumOrderAmount: 0, combinableWithCard: false }]
      })
    });
    assert.equal(match.status, 200, `${brand} 쿠폰이 ${storeName}에 매칭되어야 합니다`);
  }

  const mcpHttpServer = createMcpApp().listen(0, "127.0.0.1");
  await once(mcpHttpServer, "listening");
  const mcpAddress = mcpHttpServer.address();
  assert(mcpAddress && typeof mcpAddress !== "string");
  const client = new Client({ name: "couponcok-contract-test", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${mcpAddress.port}/mcp`));
  try {
    await client.connect(transport);
    const tools = await client.listTools();
    assert.deepEqual(tools.tools.map((tool) => tool.name).sort(), [
      "calculate_best_discount", "retrieve_carrier_benefits", "search_nearby_stores", "verify_store_with_external_maps"
    ]);

    const calculation = await client.callTool({
      name: "calculate_best_discount",
      arguments: {
        storeId: "twosome-suwon",
        storeName: "투썸플레이스 수원점",
        expectedPrice: 5_100,
        profile: { carrier: "SKT", membershipGrade: "VIP", monthlyBenefitStatus: "available" },
        coupons: [{
          id: "twosome-americano", brand: "투썸플레이스", title: "아메리카노 2,000원 할인",
          discountType: "fixedAmount", discountValue: 2_000, minimumOrderAmount: 5_000,
          combinableWithCard: true, referencePrice: 5_100
        }]
      }
    });
    const structured = calculation.structuredContent as { recommendedOption: { finalPrice: number; savings: number } };
    assert.equal(structured.recommendedOption.finalPrice, 3_100);
    assert.equal(structured.recommendedOption.savings, 2_000);
  } finally {
    await client.close();
    mcpHttpServer.close();
  }
  console.log("API contract tests passed");
} finally {
  server.close();
}
