import Foundation
import CoreLocation

/// 위치 기반 추천을 지원하는 카페·외식·편의점 프랜차이즈입니다.
enum SupportedFranchise: String, CaseIterable, Identifiable, Hashable {
    case starbucks, twosome, mega, ediya, compose, paiks, hollys, coffeebean, gongcha, theventi
    case baskinrobbins, parisbaguette, touslesjours, ashleyqueens
    case cu, gs25, seveneleven, emart24

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .starbucks: "스타벅스"
        case .twosome: "투썸플레이스"
        case .mega: "메가MGC커피"
        case .ediya: "이디야"
        case .compose: "컴포즈커피"
        case .paiks: "빽다방"
        case .hollys: "할리스"
        case .coffeebean: "커피빈"
        case .gongcha: "공차"
        case .theventi: "더벤티"
        case .baskinrobbins: "베스킨라빈스"
        case .parisbaguette: "파리바게뜨"
        case .touslesjours: "뚜레쥬르"
        case .ashleyqueens: "애슐리 퀸즈"
        case .cu: "CU"
        case .gs25: "GS25"
        case .seveneleven: "세븐일레븐"
        case .emart24: "이마트24"
        }
    }

    var storeCategory: String {
        switch self {
        case .cu, .gs25, .seveneleven, .emart24: "편의점"
        default: "카페·외식"
        }
    }

    private var aliases: [String] {
        switch self {
        case .starbucks: ["스타벅스", "starbucks"]
        case .twosome: ["투썸플레이스", "투썸", "twosomeplace", "twosome"]
        case .mega: ["메가mgc커피", "메가커피", "megacoffee", "mgccoffee"]
        case .ediya: ["이디야", "이디야커피", "ediya"]
        case .compose: ["컴포즈커피", "컴포즈", "composecoffee"]
        case .paiks: ["빽다방", "paikscoffee", "paikdabang"]
        case .hollys: ["할리스", "할리스커피", "hollys"]
        case .coffeebean: ["커피빈", "coffeebean"]
        case .gongcha: ["공차", "gongcha"]
        case .theventi: ["더벤티", "theventi"]
        case .baskinrobbins: ["베스킨라빈스", "배스킨라빈스", "baskinrobbins", "baskin"]
        case .parisbaguette: ["파리바게뜨", "파리바게트", "parisbaguette"]
        case .touslesjours: ["뚜레쥬르", "touslesjours"]
        case .ashleyqueens: ["애슐리퀸즈", "애슐리 퀸즈", "ashleyqueens", "ashley"]
        case .cu: ["cu", "씨유", "bgf리테일", "bgfretail"]
        case .gs25: ["gs25", "지에스25", "gs리테일", "gsretail"]
        case .seveneleven: ["세븐일레븐", "7eleven", "seveneleven", "코리아세븐"]
        case .emart24: ["이마트24", "emart24", "이마트이십사"]
        }
    }

    func matches(_ value: String) -> Bool {
        let candidate = Self.normalized(value)
        guard !candidate.isEmpty else { return false }
        return aliases.map(Self.normalized).contains { candidate.contains($0) || $0.contains(candidate) }
    }

    static func detected(in value: String) -> SupportedFranchise? {
        allCases.first { $0.matches(value) }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}

struct Store: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// 제출 시뮬레이션에서 사용하는 수원시 내 기준 매장입니다.
    static let suwonSubmissionTwosome = Store(
        id: "suwon-submission-twosome", name: "투썸플레이스 수원시청점", category: "카페",
        latitude: 37.2636, longitude: 127.0286, radiusMeters: 120
    )
}

enum KoreaScope {
    static let displayName = "대한민국"
    // Cloud Run과 같은 범위를 사용해 해외 좌표를 공공 매장 API와 외부 지도 도구에 전달하지 않습니다.
    static let minimumLatitude = 33.0
    static let maximumLatitude = 39.1
    static let minimumLongitude = 124.0
    static let maximumLongitude = 132.0

    static func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        minimumLatitude...maximumLatitude ~= coordinate.latitude
            && minimumLongitude...maximumLongitude ~= coordinate.longitude
    }
}

struct Coupon: Identifiable, Codable, Hashable {
    let id: String
    let brand: String
    let title: String
    let discountType: DiscountType
    let discountValue: Int
    let minimumOrderAmount: Int
    /// 퍼센트 쿠폰의 공식 최대 할인액입니다. nil이면 쿠폰 원문에서 한도를 확인해야 합니다.
    let maximumDiscount: Int?
    let expiresAt: Date
    let combinableWithCard: Bool
    /// 특정 단품 쿠폰의 계산 기준가입니다. nil이면 사용자가 입력한 장바구니 금액을 사용합니다.
    let referencePrice: Int?
    let conditions: [String]
    /// 원본 쿠폰 이미지는 앱 내부 저장소에만 보관합니다. 서버에 업로드하지 않습니다.
    let localImageFilename: String?

    init(
        id: String,
        brand: String,
        title: String,
        discountType: DiscountType,
        discountValue: Int,
        minimumOrderAmount: Int,
        maximumDiscount: Int? = nil,
        expiresAt: Date,
        combinableWithCard: Bool,
        referencePrice: Int? = nil,
        conditions: [String],
        localImageFilename: String?
    ) {
        self.id = id
        self.brand = brand
        self.title = title
        self.discountType = discountType
        self.discountValue = discountValue
        self.minimumOrderAmount = minimumOrderAmount
        self.maximumDiscount = maximumDiscount
        self.expiresAt = expiresAt
        self.combinableWithCard = combinableWithCard
        self.referencePrice = referencePrice
        self.conditions = conditions
        self.localImageFilename = localImageFilename
    }

    enum DiscountType: String, Codable { case fixedAmount, percentage }

    func matches(store: Store) -> Bool {
        matches(storeName: store.name)
    }

    func matches(storeName: String) -> Bool {
        let normalizedBrand = Self.normalized(brand)
        let normalizedStore = Self.normalized(storeName)
        guard normalizedBrand.count >= 2, !["기타", "전체", "all"].contains(normalizedBrand) else { return false }
        if let franchise = SupportedFranchise.detected(in: brand) {
            return franchise.matches(storeName)
        }
        if normalizedStore.contains(normalizedBrand) || normalizedBrand.contains(normalizedStore) { return true }
        return false
    }

    var daysUntilExpiry: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: expiresAt).day ?? 0
    }

    /// 만료일 당일은 사용할 수 있는 것으로 취급합니다.
    var isActive: Bool {
        expiresAt >= Calendar.current.startOfDay(for: .now)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    static let submissionCoupons: [Coupon] = [
        Coupon(id: "coupon-001", brand: "스타벅스", title: "음료 3,000원 할인", discountType: .fixedAmount, discountValue: 3000, minimumOrderAmount: 10000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 20), combinableWithCard: true, conditions: ["사이렌오더 제외", "타 쿠폰과 중복 불가"], localImageFilename: nil),
        Coupon(id: "coupon-002", brand: "스타벅스", title: "제조 음료 20% 할인", discountType: .percentage, discountValue: 20, minimumOrderAmount: 0, maximumDiscount: 2_000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 6), combinableWithCard: false, conditions: ["최대 2,000원 할인"], localImageFilename: nil),
        Coupon(id: "coupon-003", brand: "베스킨라빈스", title: "싱글레귤러 1+1", discountType: .fixedAmount, discountValue: 3900, minimumOrderAmount: 3900, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 14), combinableWithCard: false, conditions: ["동일 금액 또는 낮은 금액 상품 증정", "매장별 재고에 따라 사용 제한"], localImageFilename: nil),
        Coupon(id: "coupon-004", brand: "파리바게뜨", title: "3,000원 할인", discountType: .fixedAmount, discountValue: 3000, minimumOrderAmount: 15000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 9), combinableWithCard: true, conditions: ["케이크·베이커리 포함", "타 행사와 중복 불가"], localImageFilename: nil),
        Coupon(id: "coupon-005", brand: "뚜레쥬르", title: "베이커리 20% 할인", discountType: .percentage, discountValue: 20, minimumOrderAmount: 10000, maximumDiscount: 4_000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 4), combinableWithCard: false, conditions: ["최대 4,000원 할인", "일부 케이크·상품 제외"], localImageFilename: nil),
        Coupon(id: "coupon-006", brand: "애슐리 퀸즈", title: "평일 런치 5,000원 할인", discountType: .fixedAmount, discountValue: 5000, minimumOrderAmount: 20000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 18), combinableWithCard: false, conditions: ["평일 런치에 한함", "성인 1인 기준 · 타 할인 중복 불가"], localImageFilename: nil),
        Coupon(id: "coupon-007", brand: "베스킨라빈스", title: "쿼터 4,000원 할인", discountType: .fixedAmount, discountValue: 4000, minimumOrderAmount: 18000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 7), combinableWithCard: true, conditions: ["쿼터 이상 구매", "프로모션 상품 제외"], localImageFilename: nil),
        Coupon(id: "coupon-008", brand: "파리바게뜨", title: "음료 포함 20% 할인", discountType: .percentage, discountValue: 20, minimumOrderAmount: 12000, maximumDiscount: 3_000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 16), combinableWithCard: false, conditions: ["최대 3,000원 할인", "해피오더 제외"], localImageFilename: nil),
        Coupon(id: "coupon-009", brand: "뚜레쥬르", title: "케이크 4,000원 할인", discountType: .fixedAmount, discountValue: 4000, minimumOrderAmount: 25000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 11), combinableWithCard: true, conditions: ["예약 케이크 제외", "타 쿠폰과 중복 불가"], localImageFilename: nil),
        Coupon(id: "coupon-010", brand: "애슐리 퀸즈", title: "평일 디너 10% 할인", discountType: .percentage, discountValue: 10, minimumOrderAmount: 30000, maximumDiscount: 6_000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 5), combinableWithCard: false, conditions: ["최대 6,000원 할인", "주말·공휴일 제외"], localImageFilename: nil),
        Coupon(id: "coupon-011", brand: "투썸플레이스", title: "아메리카노 2,000원 할인", discountType: .fixedAmount, discountValue: 2000, minimumOrderAmount: 5000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 13), combinableWithCard: true, referencePrice: 5100, conditions: ["아메리카노 기준가 5,100원", "제조 음료에 한함", "모바일 주문 가능"], localImageFilename: nil),
        Coupon(id: "coupon-012", brand: "투썸플레이스", title: "조각 케이크 20% 할인", discountType: .percentage, discountValue: 20, minimumOrderAmount: 7000, maximumDiscount: 2_500, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 21), combinableWithCard: false, referencePrice: 7500, conditions: ["조각 케이크 기준가 7,500원", "최대 2,500원 할인", "홀케이크 제외"], localImageFilename: nil),
        Coupon(id: "coupon-013", brand: "메가MGC커피", title: "음료 1,500원 할인", discountType: .fixedAmount, discountValue: 1500, minimumOrderAmount: 4000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 8), combinableWithCard: true, conditions: ["아이스 아메리카노 포함", "1회 1잔"], localImageFilename: nil),
        Coupon(id: "coupon-014", brand: "이디야", title: "제조 음료 20% 할인", discountType: .percentage, discountValue: 20, minimumOrderAmount: 6000, maximumDiscount: 2_000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 3), combinableWithCard: false, conditions: ["최대 2,000원 할인", "배달 주문 제외"], localImageFilename: nil),
        Coupon(id: "coupon-015", brand: "컴포즈커피", title: "음료 1,000원 할인", discountType: .fixedAmount, discountValue: 1000, minimumOrderAmount: 3500, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 19), combinableWithCard: true, conditions: ["제조 음료에 한함", "타 이벤트와 중복 불가"], localImageFilename: nil),
        Coupon(id: "coupon-016", brand: "빽다방", title: "아메리카노 1,500원 할인", discountType: .fixedAmount, discountValue: 1500, minimumOrderAmount: 3000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 10), combinableWithCard: true, conditions: ["핫·아이스 선택 가능", "1일 1회"], localImageFilename: nil),
        Coupon(id: "coupon-017", brand: "할리스", title: "음료 30% 할인", discountType: .percentage, discountValue: 30, minimumOrderAmount: 7000, maximumDiscount: 3_000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 6), combinableWithCard: false, conditions: ["최대 3,000원 할인", "MD·병음료 제외"], localImageFilename: nil),
        Coupon(id: "coupon-018", brand: "커피빈", title: "제조 음료 2,000원 할인", discountType: .fixedAmount, discountValue: 2000, minimumOrderAmount: 6500, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 15), combinableWithCard: true, conditions: ["퍼플오더 제외", "1회 1잔"], localImageFilename: nil),
        Coupon(id: "coupon-019", brand: "공차", title: "토핑 추가 무료", discountType: .fixedAmount, discountValue: 1000, minimumOrderAmount: 4500, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 12), combinableWithCard: false, conditions: ["펄·코코넛 토핑 중 1개", "음료 1잔당 1회"], localImageFilename: nil),
        Coupon(id: "coupon-020", brand: "더벤티", title: "대용량 음료 1,500원 할인", discountType: .fixedAmount, discountValue: 1500, minimumOrderAmount: 4500, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 17), combinableWithCard: true, conditions: ["대용량 제조 음료", "키오스크 주문 가능"], localImageFilename: nil),
        Coupon(id: "coupon-021", brand: "스타벅스", title: "사이즈업 무료", discountType: .fixedAmount, discountValue: 600, minimumOrderAmount: 4500, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 22), combinableWithCard: false, conditions: ["Tall 이상 제조 음료", "무료 음료 쿠폰과 중복 불가"], localImageFilename: nil),
        Coupon(id: "coupon-022", brand: "파리바게뜨", title: "커피 1,000원 할인", discountType: .fixedAmount, discountValue: 1000, minimumOrderAmount: 3000, expiresAt: .now.addingTimeInterval(60 * 60 * 24 * 2), combinableWithCard: true, conditions: ["PB 카페 음료", "1일 1회"], localImageFilename: nil)
    ]
}

/// 이미지 OCR 결과를 사용자가 확인하기 전까지만 메모리에 두는 임시 데이터입니다.
struct CouponDraft: Equatable {
    var brand: String = ""
    var title: String = ""
    var discountType: Coupon.DiscountType = .fixedAmount
    var discountValue: Int = 0
    var minimumOrderAmount: Int = 0
    var maximumDiscount: Int?
    var expiresAt: Date = .now.addingTimeInterval(60 * 60 * 24 * 30)
    var combinableWithCard = false
    var conditions: [String] = []
    var requiresConfirmation = false

    mutating func applyLLMNormalization(_ normalization: CouponNormalization) {
        if let normalizedBrand = normalization.brand,
           let franchise = SupportedFranchise.detected(in: normalizedBrand) {
            brand = franchise.displayName
        }
        if let productName = normalization.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !productName.isEmpty {
            title = productName
        }
        switch normalization.discountType {
        case "percentage": discountType = .percentage
        case "fixedAmount": discountType = .fixedAmount
        default: break
        }
        if let value = normalization.discountValue, value >= 0 { discountValue = value }
        if let minimum = normalization.minimumOrderAmount, minimum >= 0 { minimumOrderAmount = minimum }
        if let expiry = normalization.expiresAt,
           let date = Self.yyyyMMdd.date(from: expiry) { expiresAt = date }
        if !normalization.conditions.isEmpty { conditions = normalization.conditions }
        requiresConfirmation = normalization.requiresConfirmation
    }

    func makeCoupon(id: String = UUID().uuidString, localImageFilename: String? = nil) -> Coupon {
        Coupon(
            id: id,
            brand: brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "기타" : brand,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "새 쿠폰" : title,
            discountType: discountType,
            discountValue: max(0, discountValue),
            minimumOrderAmount: max(0, minimumOrderAmount),
            maximumDiscount: discountType == .percentage ? maximumDiscount : nil,
            expiresAt: expiresAt,
            combinableWithCard: combinableWithCard,
            conditions: conditions,
            localImageFilename: localImageFilename
        )
    }

    private static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// 이미 사용한 쿠폰은 활성 쿠폰과 별도 컬렉션에 보관하며 추천 계산에서 제외합니다.
struct UsedCoupon: Identifiable, Codable, Hashable {
    let id: String
    let brand: String
    let productName: String
    let expiresAt: Date
    let orderNumber: String
    let barcodeLast4: String
    let usedAt: Date
    let source: String
    /// 사용자가 결제 완료를 확인한 경우에만 저장하는 최소 구매 요약입니다.
    /// 영수증·카드번호·정확한 결제내역은 수집하지 않습니다.
    let storeName: String?
    let paidAmount: Int?
    let savings: Int?
    let imageResourceName: String?
    let localImageFilename: String?
    /// 사용 완료를 되돌릴 때 할인 조건까지 그대로 복원하기 위한 원본입니다.
    /// 과거 버전에서 저장된 기록에는 값이 없을 수 있으므로 optional로 유지합니다.
    let originalCoupon: Coupon?

    init(id: String, brand: String, productName: String, expiresAt: Date, orderNumber: String, barcodeLast4: String, usedAt: Date, source: String, storeName: String? = nil, paidAmount: Int? = nil, savings: Int? = nil, imageResourceName: String? = nil, localImageFilename: String? = nil, originalCoupon: Coupon? = nil) {
        self.id = id; self.brand = brand; self.productName = productName; self.expiresAt = expiresAt
        self.orderNumber = orderNumber; self.barcodeLast4 = barcodeLast4; self.usedAt = usedAt; self.source = source
        self.storeName = storeName; self.paidAmount = paidAmount; self.savings = savings
        self.imageResourceName = imageResourceName; self.localImageFilename = localImageFilename
        self.originalCoupon = originalCoupon
    }

    init(coupon: Coupon, recommendation: Recommendation? = nil) {
        let matchedOption = recommendation?.recommendedOption.id == coupon.id ? recommendation?.recommendedOption : nil
        self.init(id: coupon.id, brand: coupon.brand, productName: coupon.title, expiresAt: coupon.expiresAt,
                  orderNumber: "앱에서 사용 처리", barcodeLast4: "-", usedAt: .now, source: "CouponPilot",
                  storeName: matchedOption == nil ? nil : recommendation?.storeName,
                  paidAmount: matchedOption?.finalPrice,
                  savings: matchedOption?.savings,
                  localImageFilename: coupon.localImageFilename, originalCoupon: coupon)
    }

    static let submissionHistory: [UsedCoupon] = [
        UsedCoupon(
            id: "used-starbucks-3336977781", brand: "스타벅스",
            productName: "아이스 카페 아메리카노 T 2잔 + 부드러운 생크림 카스텔라",
            expiresAt: date("2027-05-08"), orderNumber: "3336977781", barcodeLast4: "9847",
            usedAt: date("2026-08-10"), source: "카카오톡 선물하기",
            imageResourceName: "used-starbucks-3336977781"
        ),
        UsedCoupon(
            id: "used-starbucks-3349217463", brand: "스타벅스",
            productName: "아이스 카페 아메리카노 T 2잔",
            expiresAt: date("2027-05-19"), orderNumber: "3349217463", barcodeLast4: "5892",
            usedAt: date("2026-08-10"), source: "카카오톡 선물하기",
            imageResourceName: "used-starbucks-3349217463"
        )
    ]

    private static func date(_ value: String) -> Date {
        DateFormatter.yyyyMMdd.date(from: value) ?? .now
    }
}

/// Agent에는 원본 구매 이력 대신 이 비식별 집계만 전달합니다.
/// 정확한 사용 시각·매장·상품명·결제금액은 포함하지 않습니다.
struct BrandUsageSignal: Codable, Equatable, Hashable {
    let brand: String
    let usageCount: Int
    let daysSinceLastUse: Int
    let averageIntervalDays: Int?
}

struct PersonalizationContext: Codable, Equatable, Hashable {
    let enabled: Bool
    let historyWindowDays: Int
    let totalCouponUses: Int
    let brandSignals: [BrandUsageSignal]

    static func make(from history: [UsedCoupon], enabled: Bool, now: Date = .now) -> PersonalizationContext? {
        guard enabled else { return nil }
        let windowDays = 180
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? .distantPast
        let recent = history.filter { $0.usedAt >= cutoff && $0.usedAt <= now }
        let grouped = Dictionary(grouping: recent, by: \UsedCoupon.brand)
        let signals = grouped.map { brand, records -> BrandUsageSignal in
            let dates = records.map(\.usedAt).sorted()
            let intervals = zip(dates, dates.dropFirst()).compactMap { earlier, later in
                calendar.dateComponents([.day], from: earlier, to: later).day
            }.filter { $0 >= 0 }
            let average = intervals.isEmpty ? nil : Int(round(Double(intervals.reduce(0, +)) / Double(intervals.count)))
            let lastUsedAt = dates.last ?? now
            let daysSinceLastUse = max(0, calendar.dateComponents([.day], from: lastUsedAt, to: now).day ?? 0)
            return BrandUsageSignal(
                brand: brand,
                usageCount: records.count,
                daysSinceLastUse: daysSinceLastUse,
                averageIntervalDays: average
            )
        }
        .sorted {
            if $0.usageCount == $1.usageCount { return $0.brand < $1.brand }
            return $0.usageCount > $1.usageCount
        }
        .prefix(12)
        return PersonalizationContext(
            enabled: true,
            historyWindowDays: windowDays,
            totalCouponUses: recent.count,
            brandSignals: Array(signals)
        )
    }
}

private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct PaymentCard: Codable, Equatable, Identifiable {
    let issuer: String
    let productId: String
    let productName: String
    let previousMonthSpendQualified: Bool
    let monthlyBenefitRemainingAmount: Int

    var id: String { productId }

    static let catalog: [PaymentCard] = [
        PaymentCard(issuer: "신한카드", productId: "shinhancard-mr-life", productName: "신한카드 Mr.Life", previousMonthSpendQualified: false, monthlyBenefitRemainingAmount: 0),
        PaymentCard(issuer: "KB국민카드", productId: "kbcard-talktalk-pay", productName: "KB국민 톡톡 Pay카드", previousMonthSpendQualified: false, monthlyBenefitRemainingAmount: 0),
        PaymentCard(issuer: "현대카드", productId: "hyundaicard-m", productName: "현대카드 M", previousMonthSpendQualified: false, monthlyBenefitRemainingAmount: 0)
    ]

    static func catalogCard(productId: String?) -> PaymentCard? {
        guard let productId else { return nil }
        return catalog.first { $0.productId == productId }
    }
}

/// A source link is returned only after the card product is identified from a non-sensitive,
/// user-approved scan. It is evidence for a benefit check, never a payment authorization.
struct CardBenefitEvidence: Codable, Equatable, Identifiable {
    let title: String
    let sourceURL: String
    let limitations: String

    var id: String { sourceURL }
}

/// Gemini may nominate only an allowlisted catalog product. The user must confirm the displayed
/// product before it is persisted in `UserProfile.cards`; PAN, CVC, expiry and image data are not
/// fields in this model by design.
struct CardMultimodalRecognition: Decodable, Equatable {
    let productId: String?
    let confidence: Double
    let requiresConfirmation: Bool
    let benefitSources: [CardBenefitEvidence]

    var card: PaymentCard? { PaymentCard.catalogCard(productId: productId) }
    var needsManualSelection: Bool { card == nil || requiresConfirmation || confidence < 0.85 }
}

struct UserProfile: Codable, Equatable {
    enum MonthlyBenefitStatus: String, Codable, CaseIterable, Identifiable {
        case available
        case used
        case unknown

        var id: String { rawValue }
        var title: String {
            switch self {
            case .available: "이번 달 사용 가능"
            case .used: "이번 달 사용함"
            case .unknown: "확인 필요"
            }
        }
    }

    let id: String
    /// 카드번호·유효기간·CVC·결제내역은 수집하지 않습니다.
    let carrier: String
    let membershipGrade: String
    let monthlyBenefitStatus: MonthlyBenefitStatus
    let cards: [PaymentCard]

    init(id: String, carrier: String, membershipGrade: String = "확인 필요", monthlyBenefitStatus: MonthlyBenefitStatus = .unknown, cards: [PaymentCard] = []) {
        self.id = id
        self.carrier = carrier
        self.membershipGrade = membershipGrade
        self.monthlyBenefitStatus = monthlyBenefitStatus
        self.cards = cards
    }

    private enum CodingKeys: String, CodingKey { case id, carrier, membershipGrade, monthlyBenefitStatus, cards }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        carrier = try values.decode(String.self, forKey: .carrier)
        membershipGrade = try values.decodeIfPresent(String.self, forKey: .membershipGrade) ?? "확인 필요"
        monthlyBenefitStatus = try values.decodeIfPresent(MonthlyBenefitStatus.self, forKey: .monthlyBenefitStatus) ?? .unknown
        cards = try values.decodeIfPresent([PaymentCard].self, forKey: .cards) ?? []
    }

    static let submission = UserProfile(id: "submission-user", carrier: "LG U+", membershipGrade: "VIP", monthlyBenefitStatus: .available)
    static let empty = UserProfile(id: "local-user", carrier: "없음", membershipGrade: "확인 필요", monthlyBenefitStatus: .unknown)
}

struct PrivacyConsent: Codable, Equatable {
    static let currentPolicyVersion = "privacy-2026-08-24.v2"

    let policyVersion: String
    let requiredProcessingAccepted: Bool
    let personalizationAccepted: Bool
    let locationPersonalizationAccepted: Bool
    let acceptedAt: Date?

    var permitsService: Bool {
        requiredProcessingAccepted && policyVersion == Self.currentPolicyVersion
    }

    static let empty = PrivacyConsent(
        policyVersion: Self.currentPolicyVersion,
        requiredProcessingAccepted: false,
        personalizationAccepted: false,
        locationPersonalizationAccepted: false,
        acceptedAt: nil
    )
}

struct PriceOption: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let originalPrice: Int?
    let finalPrice: Int
    let savings: Int
    let badges: [String]
}

struct Recommendation: Codable, Hashable {
    let storeName: String
    let originalPrice: Int
    let recommendedOption: PriceOption
    let alternatives: [PriceOption]
    let explanation: String
    let benefitSources: [BenefitSource]
    let personalizationInsight: String?

    init(storeName: String, originalPrice: Int, recommendedOption: PriceOption, alternatives: [PriceOption], explanation: String, benefitSources: [BenefitSource], personalizationInsight: String? = nil) {
        self.storeName = storeName
        self.originalPrice = originalPrice
        self.recommendedOption = recommendedOption
        self.alternatives = alternatives
        self.explanation = explanation
        self.benefitSources = benefitSources
        self.personalizationInsight = personalizationInsight
    }

    static func submissionPreview(for store: Store) -> Recommendation {
        Recommendation(
        storeName: store.name, originalPrice: 5_100,
        recommendedOption: PriceOption(id: "best", title: "아메리카노 2,000원 할인", originalPrice: 5_100, finalPrice: 3_100, savings: 2_000, badges: ["단품 기준가", "쿠폰"]),
        alternatives: [
            PriceOption(id: "third", title: "조각 케이크 20% 할인", originalPrice: 7_500, finalPrice: 6_000, savings: 1_500, badges: ["단품 기준가", "쿠폰"])
        ],
        explanation: "계산기가 아메리카노 기준가 5,100원에서 쿠폰 2,000원을 차감해 최종 3,100원을 계산했어요. 통신사 혜택은 공식 앱에서 최종 적용 여부를 확인해 주세요.",
        benefitSources: []
    )
    }

}

struct BenefitSource: Codable, Hashable, Identifiable {
    let title: String
    let provider: String
    let sourceURL: String
    let checkedAt: String?
    let effectiveFrom: String?
    let effectiveTo: String?
    let version: String?
    let contentHash: String?
    let license: String?
    var id: String { "\(provider)-\(sourceURL)" }
}
