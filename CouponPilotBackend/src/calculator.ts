import type { BenefitChunk, CalculatorBenefitRule } from "./benefitRag.js";

export type Coupon = {
  id: string;
  brand: string;
  title: string;
  discountType: "fixedAmount" | "percentage";
  discountValue: number;
  minimumOrderAmount: number;
  /** Only verified maximum discount values are supplied by a confirmed coupon. */
  maximumDiscount?: number;
  /** ISO date from the client. Coupons expired before the current date are never calculated. */
  expiresAt?: string;
  combinableWithCard: boolean;
  referencePrice?: number;
};

export type RecommendationInput = {
  storeId: string;
  storeName?: string;
  expectedPrice: number;
  profile: {
    carrier: string;
    membershipGrade?: string;
    monthlyBenefitStatus?: "available" | "used" | "unknown";
    cards?: PaymentCard[];
  };
  coupons: Coupon[];
  /** Consent-gated, aggregate-only history. Raw purchases and exact timestamps are forbidden. */
  personalization?: PersonalizationContext;
};

export type PersonalizationContext = {
  enabled: true;
  historyWindowDays: number;
  totalCouponUses: number;
  brandSignals: Array<{
    brand: string;
    usageCount: number;
    daysSinceLastUse: number;
    averageIntervalDays?: number;
  }>;
};

/** No card number, expiry date, CVC or transaction history is collected. */
export type PaymentCard = {
  issuer: "신한카드" | "KB국민카드" | "현대카드";
  productId: string;
  productName: string;
  previousMonthSpendQualified: boolean;
  /** User-confirmed remaining monthly discount limit from the issuer app. */
  monthlyBenefitRemainingAmount: number;
};

export type CalculatedOption = {
  id: string;
  title: string;
  originalPrice: number;
  finalPrice: number;
  savings: number;
  badges: string[];
};

export function normalizedBrand(value: string) {
  return value.toLocaleLowerCase("ko-KR").replace(/[^\p{L}\p{N}]/gu, "");
}

/** iOS의 SupportedFranchise와 같은 지원 프랜차이즈·편의점 매장 별칭입니다. */
export const SUPPORTED_FRANCHISE_ALIASES: Record<string, string[]> = {
  "스타벅스": ["스타벅스", "starbucks"],
  "투썸플레이스": ["투썸플레이스", "투썸", "twosomeplace", "twosome"],
  "메가MGC커피": ["메가mgc커피", "메가커피", "megacoffee", "mgccoffee"],
  "이디야": ["이디야", "이디야커피", "ediya"],
  "컴포즈커피": ["컴포즈커피", "컴포즈", "composecoffee"],
  "빽다방": ["빽다방", "paikscoffee", "paikdabang"],
  "할리스": ["할리스", "할리스커피", "hollys"],
  "커피빈": ["커피빈", "coffeebean"],
  "공차": ["공차", "gongcha"],
  "더벤티": ["더벤티", "theventi"],
  "베스킨라빈스": ["베스킨라빈스", "배스킨라빈스", "baskinrobbins", "baskin"],
  "파리바게뜨": ["파리바게뜨", "파리바게트", "parisbaguette"],
  "뚜레쥬르": ["뚜레쥬르", "touslesjours"],
  "애슐리 퀸즈": ["애슐리퀸즈", "애슐리 퀸즈", "ashleyqueens", "ashley"],
  "CU": ["cu", "씨유", "bgf리테일", "bgfretail"],
  "GS25": ["gs25", "지에스25", "gs리테일", "gsretail"],
  "세븐일레븐": ["세븐일레븐", "7eleven", "seveneleven", "코리아세븐"],
  "이마트24": ["이마트24", "emart24", "이마트이십사"]
};

export function isSupportedFranchiseStore(storeName: string) {
  const store = normalizedBrand(storeName);
  return Object.values(SUPPORTED_FRANCHISE_ALIASES)
    .flat()
    .map(normalizedBrand)
    .some((alias) => store.includes(alias));
}

export function couponMatchesStore(coupon: Coupon, storeName: string) {
  const brand = normalizedBrand(coupon.brand);
  const store = normalizedBrand(storeName);
  if (brand.length < 2 || ["기타", "전체", "all"].includes(brand)) return false;
  const supported = Object.entries(SUPPORTED_FRANCHISE_ALIASES)
    .find(([, aliases]) => aliases.map(normalizedBrand).some((alias) => brand.includes(alias) || alias.includes(brand)));
  if (supported) return supported[1].map(normalizedBrand).some((alias) => store.includes(alias));
  return store.includes(brand) || brand.includes(store);
}

export function couponIsActive(coupon: Coupon, now = new Date()) {
  if (!coupon.expiresAt) return true;
  const expiresAt = new Date(coupon.expiresAt);
  if (Number.isNaN(expiresAt.valueOf())) return false;
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return expiresAt >= startOfToday;
}

function savingFromRule(rule: CalculatorBenefitRule, price: number, couponSaving: number) {
  if (price < (rule.minimumOrderAmount ?? 0)) return 0;
  if (couponSaving > 0 && rule.combinableWithCoupon !== true) return 0;
  const base = price - couponSaving;
  const raw = rule.fixedDiscount ?? (rule.discountPercent ? Math.floor(base * rule.discountPercent / 100) : 0);
  return Math.max(0, Math.min(raw, rule.maximumDiscount ?? raw, base));
}

function koreaHour() {
  return Number(new Intl.DateTimeFormat("en-US", { hour: "numeric", hourCycle: "h23", timeZone: "Asia/Seoul" }).format(new Date()));
}

export function matchingBenefitRules(profile: RecommendationInput["profile"], storeName: string, chunks: BenefitChunk[], nowHourKST = koreaHour()) {
  const unique = new Map<string, CalculatorBenefitRule>();
  for (const chunk of chunks) {
    const rule = chunk.rule;
    const matchesCarrier = rule?.appliesTo === "carrier" && profile.carrier === rule.provider;
    const matchesGrade = !rule?.eligibleGrades?.length || rule.eligibleGrades.includes(profile.membershipGrade ?? "확인 필요");
    const matchesAvailability = !rule?.requiresAvailableThisMonth || profile.monthlyBenefitStatus === "available";
    const normalizedStore = normalizedBrand(storeName);
    const matchesStore = !rule?.eligibleStoreKeywords?.length || rule.eligibleStoreKeywords.some((keyword) => normalizedStore.includes(normalizedBrand(keyword)));
    const card = rule?.appliesTo === "card" ? profile.cards?.find((candidate) => candidate.productId === rule.cardProductId) : undefined;
    const matchesCard = rule?.appliesTo === "card"
      && Boolean(card)
      && (!rule.requiresPreviousMonthSpend || card?.previousMonthSpendQualified === true)
      && (card?.monthlyBenefitRemainingAmount ?? 0) > 0;
    const matchesTime = !rule?.eligibleHoursKST?.length || rule.eligibleHoursKST.includes(nowHourKST);
    if ((matchesCarrier || matchesCard) && matchesGrade && matchesAvailability && matchesStore && matchesTime && rule) {
      const cappedRule = card
        ? { ...rule, maximumDiscount: Math.min(rule.maximumDiscount ?? Number.MAX_SAFE_INTEGER, card.monthlyBenefitRemainingAmount) }
        : rule;
      unique.set(`${cappedRule.appliesTo}:${cappedRule.provider}:${cappedRule.cardProductId ?? cappedRule.eligibleStoreKeywords?.join("-") ?? "all"}`, cappedRule);
    }
  }
  return [...unique.values()];
}

/** 결정론적 계산기: LLM이 할인액·중복 여부·순위를 추정하지 못하게 합니다. */
export function calculateOptions(input: RecommendationInput, benefitRules: CalculatorBenefitRule[]): CalculatedOption[] {
  const { expectedPrice } = input;
  const coupons = input.coupons.filter((coupon) => couponIsActive(coupon));
  const options: CalculatedOption[] = coupons.map((coupon) => {
    const basePrice = Number.isInteger(coupon.referencePrice) && coupon.referencePrice! > 0 ? coupon.referencePrice! : expectedPrice;
    const couponSaving = basePrice >= coupon.minimumOrderAmount
      ? coupon.discountType === "fixedAmount"
        ? Math.min(coupon.discountValue, basePrice)
        : Math.min(Math.floor(basePrice * coupon.discountValue / 100), coupon.maximumDiscount ?? Number.MAX_SAFE_INTEGER, basePrice)
      : 0;
    const bestBenefit = benefitRules
      .map((rule) => ({ rule, saving: savingFromRule(rule, basePrice, couponSaving) }))
      .filter((entry) => entry.saving > 0)
      .sort((left, right) => right.saving - left.saving)[0];
    const benefitSaving = bestBenefit?.saving ?? 0;
    return {
      id: coupon.id,
      title: `${coupon.title}${bestBenefit ? ` + ${bestBenefit.rule.provider}` : ""}`,
      originalPrice: basePrice,
      finalPrice: basePrice - couponSaving - benefitSaving,
      savings: couponSaving + benefitSaving,
      badges: bestBenefit ? ["쿠폰", bestBenefit.rule.appliesTo === "card" ? "카드 공식혜택" : "통신사 공식혜택"] : ["쿠폰"]
    };
  });
  for (const rule of benefitRules) {
    const saving = savingFromRule(rule, expectedPrice, 0);
    if (saving > 0) {
      options.push({
        id: `benefit-${rule.appliesTo}-${rule.provider}`,
        title: `${rule.provider} 공식 혜택`,
        originalPrice: expectedPrice,
        finalPrice: expectedPrice - saving,
        savings: saving,
        badges: [rule.appliesTo === "card" ? "카드 공식혜택" : "통신사 공식혜택"]
      });
    }
  }
  return options.sort((left, right) => right.savings - left.savings);
}
