import { Storage } from "@google-cloud/storage";
import { createHash } from "node:crypto";
import { recordAIUsage } from "./observability.js";

// V2 keeps the richer card-benefit index separate from the original carrier-only
// demo index. The runtime account can still create it once without overwrite access.
const INDEX_OBJECT = "benefits/v2/index.json";
const DOCUMENT_PREFIX = "benefits/v2/documents";
const CANDIDATE_PREFIX = "benefits/v2/candidates";
const EMBEDDING_MODEL = "gemini-embedding-001";
const MAX_OFFICIAL_SNAPSHOT_BYTES = 2 * 1024 * 1024;

export type CalculatorBenefitRule = {
  provider: string;
  appliesTo: "carrier" | "card";
  discountPercent?: number;
  fixedDiscount?: number;
  maximumDiscount?: number;
  minimumOrderAmount?: number;
  /** Omitted means that combination was not confirmed by the official source. */
  combinableWithCoupon?: boolean;
  eligibleGrades?: string[];
  requiresAvailableThisMonth?: boolean;
  eligibleStoreKeywords?: string[];
  cardProductId?: string;
  requiresPreviousMonthSpend?: boolean;
  /** Korea Standard Time hours where this benefit is valid. */
  eligibleHoursKST?: number[];
};

export type BenefitLifecycleStatus = "draft" | "reviewed" | "active" | "expired" | "withdrawn" | "retired";

/**
 * A price is intentionally separate from a discount rule. It may provide a reference price to
 * the Calculator, but can never create a discount or change the Calculator's arithmetic.
 */
export type OfficialProductPrice = {
  productName: string;
  /** OCR aliases must resolve to this one reviewed product, never a fuzzy best guess. */
  aliases?: string[];
  priceWon: number;
};

export type BenefitGovernance = {
  /** Only active documents can enter retrieval or the deterministic Calculator. */
  status: BenefitLifecycleStatus;
  /** ISO 8601 calendar date on which the official page was last checked. */
  checkedAt: string;
  /** The document automatically fails closed after this date until it is re-reviewed. */
  staleAfter: string;
  effectiveFrom?: string;
  effectiveTo?: string;
  /** Immutable source release identifier, for example 2026-08-17.v1. */
  version: string;
  reviewer: string;
  /** Human-readable rights decision. Unknown rights never pass the active gate. */
  license: string;
  limitations: string[];
};

export type BenefitChunk = {
  id: string;
  documentId: string;
  title: string;
  provider: string;
  sourceURL: string;
  text: string;
  embedding: number[];
  rule?: CalculatorBenefitRule;
  productPrices?: OfficialProductPrice[];
  lifecycleStatus?: BenefitLifecycleStatus;
  checkedAt?: string;
  staleAfter?: string;
  effectiveFrom?: string;
  effectiveTo?: string;
  version?: string;
  reviewer?: string;
  license?: string;
  contentHash?: string;
  retiredAt?: string;
  retirementReason?: string;
};

export type BenefitDocument = {
  id: string;
  title: string;
  provider: string;
  sourceURL: string;
  content: string;
  rule?: CalculatorBenefitRule;
  productPrices?: OfficialProductPrice[];
  governance: BenefitGovernance;
};

export type BenefitCandidate = {
  schemaVersion: 1;
  submittedAt: string;
  submittedBy: string;
  /** SHA-256 of the raw official HTTP response, not a reviewer-written summary. */
  sourceSnapshotHash: string;
  sourceSnapshotObject: string;
  sourceFinalURL: string;
  sourceRetrievedAt: string;
  sourceContentType: string;
  /** Hash of the structured, reviewer-authored extraction submitted for approval. */
  curatedContentHash: string;
  document: BenefitDocument;
};

const OFFICIAL_DOMAINS_BY_PROVIDER: Record<string, string[]> = {
  "SKT": ["tworld.co.kr"],
  "KT": ["kt.com"],
  "LG U+": ["lguplus.com"],
  "신한카드 Mr.Life": ["shinhancard.com"],
  "KB국민 톡톡 Pay카드": ["kbcard.com"],
  "현대카드 M": ["hyundaicard.com"],
  "스타벅스": ["starbucks.co.kr"]
};

function sha256(value: string) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function isISODate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function utcDate(value: Date) { return value.toISOString().slice(0, 10); }

function addUTCDays(value: string, days: number) {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return utcDate(date);
}

function hostMatches(host: string, allowedDomain: string) {
  return host === allowedDomain || host.endsWith(`.${allowedDomain}`);
}

function sourceURLIsOfficial(provider: string, sourceURL: string) {
  try {
    const url = new URL(sourceURL);
    const configured = (process.env.BENEFIT_OFFICIAL_DOMAIN_ALLOWLIST ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter((value) => value.includes("="))
      .map((value) => {
        const separator = value.indexOf("=");
        return { provider: value.slice(0, separator).trim(), domain: value.slice(separator + 1).trim().toLocaleLowerCase("en-US") };
      })
      .filter((value) => value.provider === provider)
      .map((value) => value.domain)
      .filter(Boolean);
    const allowedDomains = [...(OFFICIAL_DOMAINS_BY_PROVIDER[provider] ?? []), ...configured];
    return url.protocol === "https:" && allowedDomains.some((domain) => hostMatches(url.hostname.toLocaleLowerCase("en-US"), domain));
  } catch {
    return false;
  }
}

function governanceIsCurrentlyActive(governance: BenefitGovernance, now = new Date()) {
  const { status, effectiveFrom, effectiveTo, staleAfter } = governance;
  if (status !== "active") return false;
  const current = now.getTime();
  if (effectiveFrom && current < Date.parse(`${effectiveFrom}T00:00:00Z`)) return false;
  if (effectiveTo && current > Date.parse(`${effectiveTo}T23:59:59Z`)) return false;
  if (current > Date.parse(`${staleAfter}T23:59:59Z`)) return false;
  return true;
}

function validateCalculatorRule(rule: CalculatorBenefitRule, provider: string) {
  if (rule.provider !== provider) throw new Error("Calculator rule provider must match document provider");
  const stores = rule.eligibleStoreKeywords?.map((value) => value.trim()).filter(Boolean);
  if (!stores?.length) throw new Error("Calculator rules require explicit eligibleStoreKeywords");
  const finiteOptional = (value: number | undefined, name: string, minimum: number, maximum: number) => {
    if (value === undefined) return;
    if (!Number.isFinite(value) || value < minimum || value > maximum) throw new Error(`${name} is outside the allowed range`);
  };
  finiteOptional(rule.discountPercent, "discountPercent", 0, 100);
  finiteOptional(rule.fixedDiscount, "fixedDiscount", 0, 1_000_000);
  finiteOptional(rule.maximumDiscount, "maximumDiscount", 0, 1_000_000);
  finiteOptional(rule.minimumOrderAmount, "minimumOrderAmount", 0, 1_000_000);
  const hasDiscount = (rule.discountPercent ?? 0) > 0 || (rule.fixedDiscount ?? 0) > 0;
  if (!hasDiscount) throw new Error("Calculator rules require a confirmed discount value");
  if (rule.appliesTo === "card" && !rule.cardProductId?.trim()) throw new Error("Card rules require cardProductId");
  if (rule.eligibleHoursKST?.some((hour) => !Number.isInteger(hour) || hour < 0 || hour > 23)) {
    throw new Error("eligibleHoursKST must contain integers from 0 through 23");
  }
  if (rule.combinableWithCoupon === undefined) {
    throw new Error("Calculator rules require an explicit combinableWithCoupon decision");
  }
}

function normalizedProductKey(value: string) {
  return value.toLocaleLowerCase("ko-KR").replace(/[^\p{L}\p{N}]/gu, "");
}

function validateOfficialProductPrices(prices: OfficialProductPrice[] | undefined) {
  if (!prices) return;
  if (!prices.length || prices.length > 100) throw new Error("Product-price documents require between 1 and 100 entries");
  const seen = new Set<string>();
  for (const price of prices) {
    if (!price.productName.trim() || price.productName.length > 200) throw new Error("Product price requires a product name");
    if (!Number.isInteger(price.priceWon) || price.priceWon < 1 || price.priceWon > 1_000_000) {
      throw new Error("Product price must be a positive whole-won amount");
    }
    for (const value of [price.productName, ...(price.aliases ?? [])]) {
      const key = normalizedProductKey(value);
      if (key.length < 3) throw new Error("Product-price names and aliases must be specific");
      if (seen.has(key)) throw new Error("Product-price aliases must be unique within a document");
      seen.add(key);
    }
  }
}

export function validateBenefitDocument(document: BenefitDocument) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9-_]{0,127}$/u.test(document.id)) throw new Error("Document id must be a stable ASCII identifier");
  if (!document.title.trim() || document.content.trim().length < 60) throw new Error("Document title and at least 60 characters of content are required");
  if (!sourceURLIsOfficial(document.provider, document.sourceURL)) throw new Error("Source URL is not on the provider's official-domain allowlist");
  if (!isISODate(document.governance.checkedAt)) throw new Error("checkedAt must be an ISO 8601 calendar date");
  if (document.governance.checkedAt > utcDate(new Date())) throw new Error("checkedAt cannot be in the future");
  if (!isISODate(document.governance.staleAfter)) throw new Error("staleAfter must be an ISO 8601 calendar date");
  if (document.governance.staleAfter < document.governance.checkedAt) throw new Error("staleAfter must not be before checkedAt");
  if (document.governance.effectiveFrom && !isISODate(document.governance.effectiveFrom)) throw new Error("effectiveFrom must be an ISO 8601 calendar date");
  if (document.governance.effectiveTo && !isISODate(document.governance.effectiveTo)) throw new Error("effectiveTo must be an ISO 8601 calendar date");
  if (document.governance.effectiveFrom && document.governance.effectiveTo && document.governance.effectiveFrom > document.governance.effectiveTo) {
    throw new Error("effectiveFrom must not be after effectiveTo");
  }
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/u.test(document.governance.version) || !document.governance.reviewer.trim()) {
    throw new Error("A path-safe immutable version and reviewer are required");
  }
  if (!document.governance.license.trim() || /(unknown|pending|unreviewed|미확인|검토\s*중|미정)/iu.test(document.governance.license.trim())) {
    throw new Error("Active RAG documents require a reviewed license or usage-rights decision");
  }
  if (document.rule) validateCalculatorRule(document.rule, document.provider);
  validateOfficialProductPrices(document.productPrices);
  return document;
}

function reviewedGovernance(checkedAt: string, limitations: string[]): BenefitGovernance {
  return {
    status: "active",
    checkedAt,
    staleAfter: addUTCDays(checkedAt, 31),
    version: `${checkedAt}.v1`,
    reviewer: "박재현",
    license: "Official-link citation and factual paraphrase only; raw page redistribution is not permitted by this record",
    limitations
  };
}

/**
 * Initial official sources for the demo. They are deliberately source-only: the advertised
 * offers are vouchers or product/period dependent, so a price calculator must not invent a won value.
 * Cloud Run persists their embedded chunks to the configured private bucket on first retrieval.
 */
const bundledCarrierBenefits: BenefitDocument[] = [
  {
    id: "skt-tmembership-grade-guide",
    title: "SKT T 멤버십 등급 및 혜택 이용 공식 안내",
    provider: "SKT",
    sourceURL: "https://sktmembership.tworld.co.kr/mps/pc-bff/grade/gradeinfo/gradeInfo.do",
    content: `확인일: 2026-08-11\n제공자: SK텔레콤\n적용 대상: SKT T 멤버십 고객\n\nSK텔레콤의 T 멤버십 공식 안내는 VIP, GOLD, SILVER 등급 체계와 고객별 현재 등급 확인 절차를 제공한다. 제휴 할인·적립과 T day 같은 기간 한정 혜택은 브랜드, 상품, 등급, 사용 횟수와 이벤트 기간에 따라 달라질 수 있다. 따라서 CouponPilot은 매장 진입 시 T 멤버십 공식 안내를 근거로 제시하되, 할인 금액이나 이용 가능 여부를 임의로 계산하지 않는다.\n\n사용자는 T 멤버십 앱 또는 공식 웹의 나의 등급과 해당 브랜드 혜택 페이지에서 이번 달 사용 가능 여부, 행사 기간, 제외 매장을 최종 확인해야 한다. 구조화된 공식 할인 규칙이 등록된 경우에만 계산기 도구가 가격 비교에 사용한다.`,
    governance: reviewedGovernance("2026-08-11", ["브랜드·기간·등급·사용 횟수별 세부 혜택은 별도 공식 화면 확인 필요"])
  },
  {
    id: "uplus-vipkok-starbucks",
    title: "LG U+ VIP콕 스타벅스 공식 안내",
    provider: "LG U+",
    sourceURL: "https://m.lguplus.com/membership/intro",
    content: `확인일: 2026-08-10\n제공자: LG U+\n적용 대상: LG U+ VVIP 또는 VIP 멤버십 고객\n\nLG U+ 공식 멤버십 소개는 VVIP/VIP 고객이 매달 VIP콕 혜택 중 하나를 선택할 수 있으며, 선택 가능한 혜택에 스타벅스 아메리카노가 포함될 수 있음을 안내한다. VIP콕은 매달 선택하는 방식이며 영화 예매 등 다른 VIP콕 혜택과 동시에 사용할 수 없는 경우가 있다. 제공 상품, 수량, 선택 가능 여부 및 실제 사용 가능 상태는 월별로 달라질 수 있으므로 U+one 또는 U+멤버십 앱에서 최종 확인해야 한다.\n\n이 문서는 무료 교환권의 현금 가치를 임의로 계산하지 않는다. CouponPilot은 매장 진입 시 공식 근거와 확인 필요 조건을 안내하며, 사용자가 이번 달 선택 가능 상태를 직접 확인한 뒤 혜택을 사용한다.`,
    governance: reviewedGovernance("2026-08-10", ["월별 선택 가능 상품과 잔여 혜택은 앱에서 최종 확인 필요"])
  },
  {
    id: "kt-megabox-membership",
    title: "KT 멤버십 메가박스 제휴 혜택",
    provider: "KT",
    sourceURL: "https://membership.kt.com/discount/partner/C23/67/PartnerDetail.do",
    content: `확인일: 2026-08-10\n제공자: KT\n적용 대상: KT 멤버십 고객\n\nKT 멤버십 공식 제휴 브랜드 안내는 메가박스 영화 예매와 매점 콤보에 대한 멤버십 혜택을 별도로 설명한다. 영화 예매 혜택은 상영관과 요일, 티켓 금액에 따라 할인 금액이 달라질 수 있고, 매점 콤보는 지정 상품과 주문 방식에 따라 적용 조건이 다르다. 따라서 CouponPilot은 가격 입력만으로 최대 할인 금액을 확정하지 않으며, KT 멤버십 앱 또는 웹에서 상품과 잔여 혜택을 최종 확인하도록 안내한다.\n\n이 문서는 공식 혜택의 출처와 조건을 검색하기 위한 RAG 문서다. 정확한 상품 종류·회차·월별 이용 한도가 모두 확인된 구조화 규칙이 등록될 때만 계산기에 할인 규칙을 연결한다.`,
    governance: reviewedGovernance("2026-08-10", ["상품·회차·월 한도가 구조화되지 않아 계산에는 사용하지 않음"])
  }
];

/** Only fully structured official conditions are allowed to feed the Calculator. */
const bundledCardBenefits: BenefitDocument[] = [
  {
    id: "shinhancard-mr-life-night-food",
    title: "신한카드 Mr.Life TIME 할인 공식 안내",
    provider: "신한카드 Mr.Life",
    sourceURL: "https://www.shinhancard.com/pconts/html/card/apply/credit/1187937_2207.html",
    content: `확인일: 2026-08-17\n제공자: 신한카드\n상품: 신한카드 Mr.Life\n\n신한카드 Mr.Life 공식 혜택 안내에 따르면 Night TIME 할인은 승인시간 기준 오후 9시부터 오전 9시까지 식음료 업종에서 10% 할인된다. 식음료에는 한식, 양식, 일식, 중식, 뷔페, 일반대중음식, 패스트푸드, 커피전문점 업종이 포함된다. 구분 영역별 일 1회·월 10회, 1회 승인금액 1만원까지 할인되어 1회 최대 할인금액은 1천원이다. 할인 한도는 전월 이용금액 구간에 따라 제공되며, 실제 적용은 신한카드 가맹점 업종 분류와 전표 매입 순서에 따른다.\n\nCouponPilot은 사용자가 전월 실적 충족과 카드 앱에 표시된 남은 월 할인 한도를 직접 확인한 경우에만 이 구조화 규칙으로 계산한다. 카드사 공식 문서에 쿠폰 중복 규칙이 명시되지 않아 쿠폰과의 동시 적용은 제안하지 않는다.`,
    rule: {
      provider: "신한카드 Mr.Life",
      appliesTo: "card",
      cardProductId: "shinhancard-mr-life",
      discountPercent: 10,
      maximumDiscount: 1_000,
      combinableWithCoupon: false,
      requiresPreviousMonthSpend: true,
      eligibleHoursKST: [0, 1, 2, 3, 4, 5, 6, 7, 8, 21, 22, 23],
      eligibleStoreKeywords: ["스타벅스", "투썸플레이스", "메가커피", "메가MGC", "이디야", "컴포즈커피", "빽다방", "할리스", "커피빈", "공차", "더벤티", "베스킨라빈스", "파리바게뜨", "뚜레쥬르", "애슐리"]
    },
    governance: reviewedGovernance("2026-08-17", ["카드사 가맹점 업종 분류·전월 실적·일월 잔여 한도에 따라 실제 적용이 달라질 수 있음"])
  },
  {
    id: "kbcard-talktalk-pay",
    title: "KB국민 톡톡 Pay카드 공식 할인 안내",
    provider: "KB국민 톡톡 Pay카드",
    sourceURL: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?cooperationcode=09231&mainCC=a",
    content: `확인일: 2026-08-17\n제공자: KB국민카드\n상품: 톡톡 Pay카드\n\nKB국민 톡톡 Pay카드 공식 안내는 간편결제(Pay) 이용 시 전월 이용실적 40만원 이상 20%, 80만원 이상 40% 청구할인과 구간별 월 할인한도 7천원·1만5천원을 안내한다. 대상은 온·오프라인 간편결제이며 KB Pay, 삼성페이, 네이버페이, 카카오페이 등이 예시로 제시된다. 1일 할인한도는 5천원이고 일반결제(ISP)는 제외된다.\n\n실제 적용은 결제수단, 카드사 업종 코드, 전월 실적 구간, 일·월 잔여 한도와 전표 매입 순서에 좌우된다. CouponPilot은 사용자가 Pay 결제 여부와 잔여 한도를 확인하기 전에는 이 혜택을 가격 계산에 사용하지 않고 공식 근거로만 표시한다.`,
    governance: reviewedGovernance("2026-08-17", ["결제수단·실적 구간·일월 잔여 한도를 앱이 검증하지 않아 계산에는 사용하지 않음"])
  },
  {
    id: "hyundaicard-m-points",
    title: "현대카드 M 공식 M포인트 적립 안내",
    provider: "현대카드 M",
    sourceURL: "https://www.hyundaicard.com/cpc/cr/CPCCR0201_01.hc?agentCode=L300011100000&cardWcd=ME4&pmotDtlCn=lon26",
    content: `확인일: 2026-08-17\n제공자: 현대카드\n상품: 현대카드 M\n\n현대카드 M 공식 안내는 전월 이용금액 50만원 이상 시 국내외 가맹점 1.5% M포인트 적립, 100만원 이상 시 일반음식점 등에서 5% M포인트 적립을 안내한다. 일반음식점·온라인쇼핑·해외 대상점은 통합 월 1만 M포인트 한도이며, 가맹점 업종 분류와 전월 이용금액 기준이 적용된다.\n\nM포인트의 실제 결제 차감률과 사용처는 거래 조건에 따라 달라질 수 있어 CouponPilot은 이를 현금 할인으로 환산하지 않는다. 매장 진입 추천에는 공식 출처와 확인 조건만 제공한다.`,
    governance: reviewedGovernance("2026-08-17", ["포인트를 현금 할인으로 환산하지 않으며 실제 사용처·차감률 확인 필요"])
  }
];

const bundledBenefits = [...bundledCarrierBenefits, ...bundledCardBenefits];
bundledBenefits.forEach(validateBenefitDocument);
const bundledBenefitById = new Map(bundledBenefits.map((document) => [document.id, document]));

let bundleSeedPromise: Promise<BenefitChunk[]> | undefined;
// Cloud Storage is the durable index. Keep a process-local copy only when a first-run
// write is blocked by IAM, so the user still receives official source links instead of
// an invented benefit. A later deployment or request retries durable seeding.
let runtimeMemoryIndex: BenefitChunk[] = [];

function bucketName() {
  const value = process.env.BENEFITS_BUCKET;
  if (!value) throw new Error("BENEFITS_BUCKET is not configured");
  return value;
}

function storage() { return new Storage(); }

function chunks(content: string, length = 900, overlap = 150) {
  const normalized = content.replace(/\r\n/g, "\n").trim();
  const results: string[] = [];
  for (let start = 0; start < normalized.length; start += length - overlap) {
    const part = normalized.slice(start, start + length).trim();
    if (part.length >= 60) results.push(part);
    if (start + length >= normalized.length) break;
  }
  return results;
}

async function embeddingsFor(values: string[]) {
  const project = process.env.VERTEX_PROJECT_ID;
  if (!project) throw new Error("VERTEX_PROJECT_ID is not configured");
  const { GoogleGenAI } = await import("@google/genai");
  const client = new GoogleGenAI({ vertexai: true, project, location: process.env.VERTEX_LOCATION ?? "global" });
  const response = await client.models.embedContent({
    model: EMBEDDING_MODEL,
    contents: values,
    config: { outputDimensionality: 768 }
  });
  const embeddings = response.embeddings ?? [];
  if (embeddings.length !== values.length) throw new Error("Unexpected embedding response");
  recordAIUsage({ operation: "benefit_embedding", model: EMBEDDING_MODEL, items: values.length });
  return embeddings.map((embedding) => embedding.values ?? []);
}

type BenefitIndexSnapshot = { chunks: BenefitChunk[]; generation: number };

function governedChunk(document: BenefitDocument, text: string, embedding: number[], partIndex: number): BenefitChunk {
  const contentHash = sha256(document.content);
  return {
    id: `${document.id}-${document.governance.version}-${partIndex + 1}`,
    documentId: document.id,
    title: document.title,
    provider: document.provider,
    sourceURL: document.sourceURL,
    text,
    embedding,
    rule: document.rule,
    productPrices: document.productPrices,
    lifecycleStatus: document.governance.status,
    checkedAt: document.governance.checkedAt,
    staleAfter: document.governance.staleAfter,
    effectiveFrom: document.governance.effectiveFrom,
    effectiveTo: document.governance.effectiveTo,
    version: document.governance.version,
    reviewer: document.governance.reviewer,
    license: document.governance.license,
    contentHash
  };
}

/** Upgrade only known bundled V1 chunks. Unknown legacy documents fail closed until re-ingested. */
function enrichLegacyChunk(chunk: BenefitChunk): BenefitChunk | undefined {
  if (chunk.lifecycleStatus && chunk.checkedAt && chunk.staleAfter && chunk.version && chunk.reviewer && chunk.license && chunk.contentHash) return chunk;
  const document = bundledBenefitById.get(chunk.documentId);
  if (!document) return undefined;
  return {
    ...chunk,
    lifecycleStatus: document.governance.status,
    checkedAt: document.governance.checkedAt,
    staleAfter: document.governance.staleAfter,
    effectiveFrom: document.governance.effectiveFrom,
    effectiveTo: document.governance.effectiveTo,
    version: document.governance.version,
    reviewer: document.governance.reviewer,
    license: document.governance.license,
    contentHash: sha256(document.content),
    rule: document.rule,
    productPrices: document.productPrices
  };
}

function chunkIsRetrievable(chunk: BenefitChunk, now = new Date()) {
  const strings = [chunk.id, chunk.documentId, chunk.title, chunk.provider, chunk.sourceURL, chunk.text];
  if (strings.some((value) => typeof value !== "string" || !value.trim())) return false;
  if (!Array.isArray(chunk.embedding) || !chunk.embedding.length || chunk.embedding.some((value) => !Number.isFinite(value))) return false;
  if (!["draft", "reviewed", "active", "expired", "withdrawn", "retired"].includes(chunk.lifecycleStatus ?? "")) return false;
  if (!chunk.lifecycleStatus || !chunk.checkedAt || !chunk.staleAfter || !chunk.version || !chunk.reviewer || !chunk.license || !chunk.contentHash) return false;
  if (!isISODate(chunk.checkedAt) || !isISODate(chunk.staleAfter) || chunk.checkedAt > utcDate(now) || chunk.staleAfter < chunk.checkedAt) return false;
  if (!/^[a-f0-9]{64}$/u.test(chunk.contentHash) || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/u.test(chunk.version)) return false;
  if (/(unknown|pending|unreviewed|미확인|검토\s*중|미정)/iu.test(chunk.license)) return false;
  if (!sourceURLIsOfficial(chunk.provider, chunk.sourceURL)) return false;
  try {
    if (chunk.rule) validateCalculatorRule(chunk.rule, chunk.provider);
    validateOfficialProductPrices(chunk.productPrices);
  } catch {
    return false;
  }
  return governanceIsCurrentlyActive({
    status: chunk.lifecycleStatus,
    checkedAt: chunk.checkedAt,
    staleAfter: chunk.staleAfter,
    effectiveFrom: chunk.effectiveFrom,
    effectiveTo: chunk.effectiveTo,
    version: chunk.version,
    reviewer: chunk.reviewer,
    license: chunk.license,
    limitations: []
  }, now);
}

async function loadIndexSnapshot(): Promise<BenefitIndexSnapshot> {
  const file = storage().bucket(bucketName()).file(INDEX_OBJECT);
  const [exists] = await file.exists();
  if (!exists) return { chunks: [], generation: 0 };
  const [metadata] = await file.getMetadata();
  const generation = Number(metadata.generation);
  if (!Number.isSafeInteger(generation) || generation <= 0) throw new Error("Benefit index generation is invalid");
  const [body] = await file.download();
  const parsed = JSON.parse(body.toString("utf8")) as { chunks?: BenefitChunk[] };
  return { chunks: Array.isArray(parsed.chunks) ? parsed.chunks : [], generation };
}

function candidateObjectName(documentId: string, version: string) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9-_]{0,127}$/u.test(documentId)) throw new Error("Invalid candidate document id");
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/u.test(version)) throw new Error("Invalid candidate version");
  return `${CANDIDATE_PREFIX}/${documentId}/${version}.json`;
}

function candidateSnapshotObjectName(documentId: string, version: string, contentType: string) {
  const extension = contentType.includes("pdf") ? "pdf" : contentType.includes("html") ? "html" : "txt";
  return `${CANDIDATE_PREFIX}/${documentId}/${version}/source.${extension}`;
}

type CapturedOfficialSource = {
  bytes: Buffer;
  hash: string;
  finalURL: string;
  retrievedAt: string;
  contentType: string;
};

/** Capture the exact official response and bind it to the provider allowlist after redirects. */
async function captureOfficialSource(document: BenefitDocument): Promise<CapturedOfficialSource> {
  const response = await fetch(document.sourceURL, {
    redirect: "follow",
    headers: { "user-agent": "CouponCock-benefit-review/1.0 (+official-source-verification)" },
    signal: AbortSignal.timeout(15_000)
  });
  if (!response.ok) throw new Error(`Official source returned HTTP ${response.status}`);
  if (!sourceURLIsOfficial(document.provider, response.url)) throw new Error("Official source redirect left the provider allowlist");
  const contentType = response.headers.get("content-type")?.split(";", 1)[0].trim().toLocaleLowerCase("en-US") ?? "application/octet-stream";
  if (!/(text\/html|application\/pdf|text\/plain)/u.test(contentType)) throw new Error(`Official source content type is not reviewable: ${contentType}`);
  const declaredSize = Number(response.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredSize) && declaredSize > MAX_OFFICIAL_SNAPSHOT_BYTES) throw new Error("Official source exceeds snapshot size limit");
  const bytes = Buffer.from(await response.arrayBuffer());
  if (!bytes.length || bytes.length > MAX_OFFICIAL_SNAPSHOT_BYTES) throw new Error("Official source snapshot is empty or exceeds size limit");
  return { bytes, hash: sha256(bytes.toString("base64")), finalURL: response.url, retrievedAt: new Date().toISOString(), contentType };
}

function reviewedCandidateDocument(document: BenefitDocument) {
  validateBenefitDocument(document);
  if (document.governance.status !== "reviewed") {
    throw new Error("Benefit candidates must be reviewed before they can wait for approval");
  }
  return document;
}

/**
 * Candidate submission is deliberately storage-only: it neither embeds the text nor changes the
 * live vector index. This makes a pasted rule, changed terms page, or unreviewed condition unable
 * to affect Calculator input until an independent approver promotes the immutable snapshot.
 */
export async function submitOfficialBenefitCandidate(document: BenefitDocument, submittedBy: string) {
  reviewedCandidateDocument(document);
  if (!submittedBy.trim()) throw new Error("Candidate submission requires an operator identity");
  const source = await captureOfficialSource(document);
  const snapshotObject = candidateSnapshotObjectName(document.id, document.governance.version, source.contentType);
  const candidate: BenefitCandidate = {
    schemaVersion: 1,
    submittedAt: new Date().toISOString(),
    submittedBy: submittedBy.trim(),
    sourceSnapshotHash: source.hash,
    sourceSnapshotObject: snapshotObject,
    sourceFinalURL: source.finalURL,
    sourceRetrievedAt: source.retrievedAt,
    sourceContentType: source.contentType,
    curatedContentHash: sha256(document.content),
    document
  };
  const objectName = candidateObjectName(document.id, document.governance.version);
  await storage().bucket(bucketName()).file(snapshotObject).save(source.bytes, {
    contentType: source.contentType,
    resumable: false,
    preconditionOpts: { ifGenerationMatch: 0 },
    metadata: {
      metadata: {
        sourceURL: source.finalURL,
        sourceSnapshotHash: source.hash,
        retrievedAt: source.retrievedAt,
        documentId: document.id,
        version: document.governance.version
      }
    }
  });
  await storage().bucket(bucketName()).file(objectName).save(JSON.stringify(candidate), {
    contentType: "application/json",
    resumable: false,
    preconditionOpts: { ifGenerationMatch: 0 }
  });
  return {
    documentId: document.id,
    version: document.governance.version,
    status: "candidate" as const,
    sourceSnapshotHash: candidate.sourceSnapshotHash,
    sourceSnapshotObject: candidate.sourceSnapshotObject,
    curatedContentHash: candidate.curatedContentHash,
    objectName
  };
}

async function loadOfficialBenefitCandidate(documentId: string, version: string): Promise<BenefitCandidate> {
  const objectName = candidateObjectName(documentId, version);
  const file = storage().bucket(bucketName()).file(objectName);
  const [exists] = await file.exists();
  if (!exists) throw new Error("Benefit candidate was not found");
  const [body] = await file.download();
  let candidate: BenefitCandidate;
  try {
    candidate = JSON.parse(body.toString("utf8")) as BenefitCandidate;
  } catch {
    throw new Error("Benefit candidate JSON is invalid");
  }
  if (candidate.schemaVersion !== 1 || !candidate.submittedAt || !candidate.submittedBy || !candidate.sourceSnapshotHash || !candidate.sourceSnapshotObject || !candidate.sourceFinalURL || !candidate.sourceRetrievedAt || !candidate.sourceContentType || !candidate.curatedContentHash || !candidate.document) {
    throw new Error("Benefit candidate metadata is incomplete");
  }
  reviewedCandidateDocument(candidate.document);
  if (candidate.document.id !== documentId || candidate.document.governance.version !== version) {
    throw new Error("Benefit candidate identity does not match its storage path");
  }
  if (candidate.curatedContentHash !== sha256(candidate.document.content)) {
    throw new Error("Benefit candidate curated content hash does not match its content");
  }
  if (!sourceURLIsOfficial(candidate.document.provider, candidate.sourceFinalURL)) throw new Error("Benefit candidate source URL is outside the provider allowlist");
  const snapshot = storage().bucket(bucketName()).file(candidate.sourceSnapshotObject);
  const [snapshotExists] = await snapshot.exists();
  if (!snapshotExists) throw new Error("Benefit candidate official source snapshot is missing");
  const [bytes] = await snapshot.download();
  if (sha256(bytes.toString("base64")) !== candidate.sourceSnapshotHash) throw new Error("Benefit candidate official source snapshot hash does not match");
  return candidate;
}

async function loadIndex(): Promise<BenefitChunk[]> {
  if (runtimeMemoryIndex.length) return runtimeMemoryIndex.filter((chunk) => chunkIsRetrievable(chunk));
  try {
    return (await loadIndexSnapshot()).chunks
      .map(enrichLegacyChunk)
      .filter((chunk): chunk is BenefitChunk => Boolean(chunk))
      .filter((chunk) => chunkIsRetrievable(chunk));
  } catch (error) {
    console.warn("Benefit index read unavailable; attempting bundled official documents", error instanceof Error ? error.message : error);
    return [];
  }
}

async function saveIndex(index: BenefitChunk[], expectedGeneration: number) {
  await storage().bucket(bucketName()).file(INDEX_OBJECT).save(JSON.stringify({
    schemaVersion: 2,
    updatedAt: new Date().toISOString(),
    chunks: index
  }), {
    contentType: "application/json",
    resumable: false,
    preconditionOpts: { ifGenerationMatch: expectedGeneration }
  });
}

function similarity(a: number[], b: number[]) {
  let dot = 0, normA = 0, normB = 0;
  for (let index = 0; index < Math.min(a.length, b.length); index += 1) {
    dot += a[index] * b[index]; normA += a[index] ** 2; normB += b[index] ** 2;
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB) || 1);
}

/**
 * The recommendation flow always includes the profile's carrier in its query. When that
 * carrier is explicit, do not show a semantically-similar benefit from another carrier as
 * evidence. Generic queries still use the whole vector index.
 */
function explicitlyRequestedProviders(query: string) {
  const normalized = query.toLocaleLowerCase("ko-KR").replace(/[^\p{L}\p{N}]/gu, "");
  const lowercased = query.toLocaleLowerCase("ko-KR");
  const providers: string[] = [];
  if (["skt", "sk텔레콤", "t멤버십"].some((token) => normalized.includes(token))) providers.push("SKT");
  // Do not test normalized text for bare "kt": it is contained in "skt".
  if (normalized.includes("케이티") || normalized.includes("kt멤버십") || /(?:^|\s)kt(?:$|\s)/u.test(lowercased)) providers.push("KT");
  if (["lgu", "lg유플러스", "u멤버십", "uplus"].some((token) => normalized.includes(token))) providers.push("LG U+");
  if (["신한카드mrlife", "mrlife"].some((token) => normalized.includes(token))) providers.push("신한카드 Mr.Life");
  if (["kb국민톡톡pay", "톡톡pay", "톡톡페이"].some((token) => normalized.includes(token))) providers.push("KB국민 톡톡 Pay카드");
  if (["현대카드m", "hyundaicardm"].some((token) => normalized.includes(token))) providers.push("현대카드 M");
  return providers;
}

export async function searchOfficialBenefits(query: string, limit = 4) {
  let index = await loadIndex();
  if (!index.length) index = await seedBundledCarrierBenefits();
  if (!index.length) return [];
  const explicitProviders = explicitlyRequestedProviders(query);
  const candidates = explicitProviders.length
    ? index.filter((chunk) => explicitProviders.includes(chunk.provider))
    : index;
  const [queryEmbedding] = await embeddingsFor([query]);
  const configuredThreshold = Number(process.env.BENEFIT_RAG_MIN_SCORE ?? 0.35);
  const minimumScore = Number.isFinite(configuredThreshold) ? Math.min(1, Math.max(0, configuredThreshold)) : 0.35;
  return candidates
    .map((chunk) => ({ ...chunk, score: similarity(queryEmbedding, chunk.embedding) }))
    .filter((chunk) => chunk.score >= minimumScore)
    .sort((left, right) => right.score - left.score)
    .slice(0, limit);
}

export type OfficialProductPriceMatch = {
  brand: string;
  productName: string;
  priceWon: number;
  sourceTitle: string;
  sourceURL: string;
  checkedAt: string;
  version: string;
};

/**
 * Exact product-catalog lookup for an OCR result. This deliberately does not use semantic
 * similarity: returning a nearby menu item with a different size or composition would be a
 * price hallucination. Conflicting active sources also fail closed.
 */
export async function findOfficialProductPrice(brand: string, productName: string): Promise<OfficialProductPriceMatch | undefined> {
  const normalizedBrand = normalizedProductKey(brand);
  const normalizedProduct = normalizedProductKey(productName);
  if (normalizedBrand.length < 2 || normalizedProduct.length < 3) return undefined;

  const index = await loadIndex();
  const matches = index.flatMap((chunk) => {
    if (normalizedProductKey(chunk.provider) !== normalizedBrand) return [];
    return (chunk.productPrices ?? [])
      .filter((entry) => [entry.productName, ...(entry.aliases ?? [])].some((value) => normalizedProductKey(value) === normalizedProduct))
      .map((entry) => ({
        brand: chunk.provider,
        productName: entry.productName,
        priceWon: entry.priceWon,
        sourceTitle: chunk.title,
        sourceURL: chunk.sourceURL,
        checkedAt: chunk.checkedAt!,
        version: chunk.version!
      }));
  });
  const distinctPrices = new Set(matches.map((match) => `${match.priceWon}:${match.sourceURL}:${match.version}`));
  return distinctPrices.size === 1 ? matches[0] : undefined;
}

async function seedBundledCarrierBenefits(): Promise<BenefitChunk[]> {
  if (!bundleSeedPromise) {
    bundleSeedPromise = (async () => {
      const current = await loadIndex();
      if (current.length) return current;

      // Bundled records have already passed official-domain and governance validation above.
      const parts = bundledBenefits.flatMap((document) => chunks(document.content).map((text, partIndex) => ({ document, text, partIndex })));
      const vectors = await embeddingsFor(parts.map((part) => part.text));
      const nextIndex = parts.map((part, index) => governedChunk(part.document, part.text, vectors[index], part.partIndex));
      runtimeMemoryIndex = nextIndex;
      if (process.env.BENEFIT_RUNTIME_SEED_PERSIST === "true") {
        try {
          const bucket = storage().bucket(bucketName());
          for (const document of bundledBenefits) {
            const objectName = `${DOCUMENT_PREFIX}/${document.id}/${document.governance.version}.md`;
            await bucket.file(objectName).save(document.content, {
              contentType: "text/markdown; charset=utf-8", resumable: false, preconditionOpts: { ifGenerationMatch: 0 }
            });
          }
          await bucket.file(INDEX_OBJECT).save(JSON.stringify({ schemaVersion: 2, updatedAt: new Date().toISOString(), chunks: nextIndex }), {
            contentType: "application/json", resumable: false, preconditionOpts: { ifGenerationMatch: 0 }
          });
        } catch (error) {
          console.warn("Bundled benefit persistence failed; the read-only API will use its in-memory fallback", error instanceof Error ? error.message : error);
        }
      }
      return nextIndex;
    })().catch((error) => {
      // Do not cache a transient IAM or Vertex failure forever; a later request can retry.
      bundleSeedPromise = undefined;
      throw error;
    });
  }
  return bundleSeedPromise;
}

async function promoteOfficialBenefit(document: BenefitDocument) {
  validateBenefitDocument(document);
  if (!governanceIsCurrentlyActive(document.governance)) throw new Error("Only currently active, reviewed documents can be promoted to the retrieval index");
  const documentChunks = chunks(document.content);
  if (!documentChunks.length) throw new Error("Document needs at least 60 characters of benefit text");
  const vectors = await embeddingsFor(documentChunks);
  const nextChunks = documentChunks.map((text, index) => governedChunk(document, text, vectors[index], index));
  const bucket = storage().bucket(bucketName());
  const documentObject = `${DOCUMENT_PREFIX}/${document.id}/${document.governance.version}.md`;
  await bucket.file(documentObject).save(document.content, {
    contentType: "text/markdown; charset=utf-8",
    resumable: false,
    preconditionOpts: { ifGenerationMatch: 0 }
  });
  const snapshot = await loadIndexSnapshot();
  const current = snapshot.chunks.map(enrichLegacyChunk).filter((chunk): chunk is BenefitChunk => Boolean(chunk));
  await saveIndex([...current.filter((chunk) => chunk.documentId !== document.id), ...nextChunks], snapshot.generation);
  runtimeMemoryIndex = [];
  return {
    documentId: document.id,
    version: document.governance.version,
    contentHash: sha256(document.content),
    chunkCount: nextChunks.length
  };
}

/**
 * Compatibility path for trusted migration jobs. New operational ingestion must use
 * submitOfficialBenefitCandidate() and approveOfficialBenefitCandidate() below.
 */
export async function ingestOfficialBenefit(document: BenefitDocument) {
  return promoteOfficialBenefit(document);
}

/** Promote a reviewed immutable candidate into the live index after a second human approves it. */
export async function approveOfficialBenefitCandidate(documentId: string, version: string, approvedBy: string) {
  if (!approvedBy.trim()) throw new Error("Benefit approval requires an operator identity");
  const candidate = await loadOfficialBenefitCandidate(documentId, version);
  if (candidate.submittedBy === approvedBy.trim() && process.env.BENEFIT_ALLOW_SELF_APPROVAL !== "true") {
    throw new Error("A different reviewer must approve a benefit candidate before production promotion");
  }
  const approvedDocument: BenefitDocument = {
    ...candidate.document,
    governance: {
      ...candidate.document.governance,
      status: "active",
      reviewer: approvedBy.trim()
    }
  };
  const result = await promoteOfficialBenefit(approvedDocument);
  return {
    ...result,
    status: "active" as const,
    candidateSubmittedAt: candidate.submittedAt,
    candidateSubmittedBy: candidate.submittedBy,
    sourceSnapshotHash: candidate.sourceSnapshotHash,
    sourceSnapshotObject: candidate.sourceSnapshotObject,
    sourceFinalURL: candidate.sourceFinalURL,
    sourceRetrievedAt: candidate.sourceRetrievedAt,
    curatedContentHash: candidate.curatedContentHash,
    approvedBy: approvedBy.trim()
  };
}

/**
 * Keep a tombstone for audit while immediately removing a withdrawn document from retrieval
 * and the deterministic Calculator. The optimistic generation check prevents lost updates.
 */
export async function retireOfficialBenefit(documentId: string, reason: string, actor: string) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9-_]{0,127}$/u.test(documentId)) throw new Error("Invalid document id");
  if (reason.trim().length < 5 || !actor.trim()) throw new Error("A retirement reason and actor are required");
  const snapshot = await loadIndexSnapshot();
  let affectedChunks = 0;
  const retiredAt = new Date().toISOString();
  const next = snapshot.chunks.map((chunk) => {
    if (chunk.documentId !== documentId) return chunk;
    affectedChunks += 1;
    return {
      ...chunk,
      lifecycleStatus: "retired" as const,
      reviewer: actor.trim(),
      retiredAt,
      retirementReason: reason.trim()
    };
  });
  if (!affectedChunks) throw new Error("Benefit document was not found in the active index");
  await saveIndex(next, snapshot.generation);
  runtimeMemoryIndex = [];
  return { documentId, status: "retired" as const, retiredAt, retirementReason: reason.trim(), affectedChunks };
}
