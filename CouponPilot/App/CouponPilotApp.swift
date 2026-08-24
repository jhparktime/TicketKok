import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseAppCheck
import FirebaseCore

@main
struct CouponPilotApp: App {
    @StateObject private var appState = AppState()

    init() {
        // GoogleService-Info.plist가 번들에 포함된 실제 앱에서만 Firebase를 초기화합니다.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            #if targetEnvironment(simulator)
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            #else
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
            #endif
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// Submission runs are opt-in. A normal simulator, TestFlight, and App Store build always
    /// starts with the user's own wallet and never loads this scenario.
    static let isNotificationCapture = ProcessInfo.processInfo.arguments.contains("-CouponCokNotificationCapture")
    static let isSubmissionSimulation = ProcessInfo.processInfo.arguments.contains("-CouponCokSubmission")
        || isNotificationCapture
        || ProcessInfo.processInfo.environment["COUPONCOK_SUBMISSION"] == "1"
    /// Screenshot-only destination. It has no effect unless the opt-in submission simulation is enabled.
    static let captureTarget: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CouponCokCapture"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()

    static var captureInitialTab: String {
        switch captureTarget {
        case "coupons": "coupons"
        case "history": "history"
        case "profile", "card": "profile"
        default: "home"
        }
    }

    private struct NotificationRecommendationContext: Codable {
        let store: Store
        let recommendation: Recommendation
    }

    private static let notificationRecommendationContextKey = "notification-recommendation-context"
    private static let privacyConsentKey = "privacy-consent-v1"
    private static let pendingRestoredCouponIDsKey = "pending-restored-coupon-ids"
    private static let pendingDeletedCouponIDsKey = "pending-deleted-coupon-ids"
    enum StoreDirectoryState: Equatable {
        case awaitingLocation, loading, live, empty, unavailable

        var message: String {
            switch self {
            case .awaitingLocation: "위치를 확인하면 주변 매장을 불러올게요"
            case .loading: "현재 위치 주변 매장 정보를 불러오는 중이에요"
            case .live: "주변 대상 매장을 감지하고 있어요"
            case .empty: "현재 위치 근처에 대상 매장이 없어요"
            case .unavailable: "매장 목록을 불러오지 못했어요"
            }
        }
    }

    enum CloudSyncState: Equatable {
        case localOnly, syncing, synced, needsRetry
    }

    enum AccountStatus: Equatable {
        case unavailable, guest, apple, submission

        var title: String {
            switch self {
            case .unavailable: "로그인 준비 중"
            case .guest: "기기 임시 계정"
            case .apple: "Apple 계정으로 로그인됨"
            case .submission: "박재현님으로 로그인됨"
            }
        }

        var detail: String {
            switch self {
            case .unavailable: "Firebase 설정을 확인한 뒤 로그인할 수 있어요."
            case .guest: "Apple로 로그인하면 쿠폰과 설정을 내 계정에 연결할 수 있어요."
            case .apple: "새 기기에서도 Apple 로그인을 통해 쿠폰과 설정을 불러올 수 있어요."
            case .submission: "박재현의 쿠폰·멤버십 설정이 계정에 안전하게 동기화되어 있어요."
            }
        }

        var isSignedIn: Bool {
            self == .apple || self == .submission
        }
    }

    @Published var currentStore: Store?
    @Published var recommendation: Recommendation?
    @Published private(set) var activeRecommendationOption: PriceOption?
    @Published var isLoadingRecommendation = false
    @Published var shouldShowRecommendation = false
    @Published private(set) var firebaseUserID: String?
    @Published private(set) var firebaseReady = false
    @Published private(set) var accountStatus: AccountStatus = .unavailable
    @Published private(set) var cloudSyncState: CloudSyncState = .localOnly
    @Published private(set) var privacyConsent: PrivacyConsent
    private var firebaseAuthenticationTask: Task<Void, Never>?
    private var cloudReconciliationTask: Task<Void, Never>?

    @Published private(set) var profile: UserProfile
    @Published private(set) var coupons: [Coupon]
    @Published private(set) var nearbyStores: [Store] = []
    @Published private(set) var storeDirectoryState: StoreDirectoryState = .awaitingLocation
    @Published private(set) var usedCoupons: [UsedCoupon]
    /// 사용 완료 직후 5초 동안 전역 실행 취소 배너에 노출할 원본 쿠폰입니다.
    @Published private(set) var recentlyUsedCoupon: Coupon?
    private var couponUndoExpirationTask: Task<Void, Never>?
    @Published private(set) var recentlyDeletedCoupon: Coupon?
    private var couponDeletionUndoExpirationTask: Task<Void, Never>?
    /// 오프라인 복원 후 원격 usedCoupons 문서가 삭제되기 전까지 유지하는 로컬 tombstone입니다.
    private var pendingRestoredCouponIDs: Set<String> = []
    private var pendingDeletedCouponIDs: Set<String> = []

    /// 개인화 동의가 있을 때만 최근 사용 이력을 비식별 집계로 변환합니다.
    /// Agent에는 원본 사용 기록·정확한 시각·매장·상품명·결제금액을 보내지 않습니다.
    var recommendationPersonalizationContext: PersonalizationContext? {
        PersonalizationContext.make(
            from: usedCoupons,
            enabled: privacyConsent.personalizationAccepted
        )
    }

    init() {
        if Self.isSubmissionSimulation {
            privacyConsent = PrivacyConsent(
                policyVersion: PrivacyConsent.currentPolicyVersion,
                requiredProcessingAccepted: true,
                personalizationAccepted: true,
                locationPersonalizationAccepted: false,
                acceptedAt: .now
            )
            pendingRestoredCouponIDs = []
            pendingDeletedCouponIDs = []
            usedCoupons = UsedCoupon.submissionHistory
            recentlyUsedCoupon = nil
            recentlyDeletedCoupon = nil
            coupons = Coupon.submissionCoupons
            if Self.captureTarget == "barcode", let coupon = Coupon.submissionCoupons.first {
                // 시연 캡처에서만 기기 Keychain에 저장하는 표시용 교환 코드입니다.
                // 일반 실행·Firestore·API 요청에는 포함되지 않습니다.
                try? SecureCouponBarcodeStore.save(
                    CouponBarcodeCandidate(value: "8801234567890", format: .code128),
                    couponID: coupon.id
                )
            }
            profile = .submission
            nearbyStores = [.suwonSubmissionTwosome]
            storeDirectoryState = .live
            firebaseUserID = "submission-jaehyun-park"
            firebaseReady = true
            accountStatus = .submission
            cloudSyncState = .synced
            if Self.captureTarget == "recommendation" {
                currentStore = .suwonSubmissionTwosome
                recommendation = .submissionPreview(for: .suwonSubmissionTwosome)
                shouldShowRecommendation = true
            }
            return
        }

        privacyConsent = Self.loadPrivacyConsent()
        pendingRestoredCouponIDs = Self.loadPendingRestoredCouponIDs()
        pendingDeletedCouponIDs = Self.loadPendingDeletedCouponIDs()
        let allUsedCoupons = Self.loadSavedUsedCoupons()
        let usedIDs = Set(allUsedCoupons.map(\.id))
        let savedCoupons = Self.loadSavedCoupons().filter { !usedIDs.contains($0.id) }
        usedCoupons = allUsedCoupons
        recentlyUsedCoupon = nil
        coupons = savedCoupons
        profile = Self.loadSavedProfile()

        guard FirebaseApp.app() != nil else { return }

        firebaseReady = true
        refreshAccountStatus()
        guard privacyConsent.permitsService else { return }
        cloudSyncState = .syncing
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            refreshAccountStatus()
            Task { await hydrateFirebaseData(uid: user.uid) }
        } else {
            startFirebaseAuthenticationIfNeeded()
        }
    }

    /// Location callbacks can happen before the anonymous sign-in started at launch completes.
    /// Wait for that one shared task so a real store entry never falls back to an API error.
    func ensureFirebaseAuthentication() async -> Bool {
        guard privacyConsent.permitsService else { return false }
        guard FirebaseApp.app() != nil else { return false }
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            refreshAccountStatus()
            return true
        }
        startFirebaseAuthenticationIfNeeded()
        await firebaseAuthenticationTask?.value
        return Auth.auth().currentUser != nil
    }

    private func startFirebaseAuthenticationIfNeeded() {
        guard privacyConsent.permitsService else { return }
        guard firebaseAuthenticationTask == nil else { return }
        firebaseAuthenticationTask = Task { [weak self] in
            guard let self else { return }
            defer { firebaseAuthenticationTask = nil }
            do {
                let result = try await Auth.auth().signInAnonymously()
                firebaseUserID = result.user.uid
                refreshAccountStatus()
                await hydrateFirebaseData(uid: result.user.uid)
            } catch {
                cloudSyncState = .needsRetry
                print("Firebase anonymous authentication unavailable: \(error.localizedDescription)")
            }
        }
    }

    func acceptPrivacyConsent(personalization: Bool, locationPersonalization: Bool) {
        let consent = PrivacyConsent(
            policyVersion: PrivacyConsent.currentPolicyVersion,
            requiredProcessingAccepted: true,
            personalizationAccepted: personalization,
            locationPersonalizationAccepted: locationPersonalization,
            acceptedAt: .now
        )
        privacyConsent = consent
        persistPrivacyConsent(consent)
        guard FirebaseApp.app() != nil else { return }
        firebaseReady = true
        refreshAccountStatus()
        cloudSyncState = .syncing
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            refreshAccountStatus()
            Task { await hydrateFirebaseData(uid: user.uid) }
        } else {
            startFirebaseAuthenticationIfNeeded()
        }
    }

    func updateOptionalConsents(personalization: Bool, locationPersonalization: Bool) {
        guard privacyConsent.permitsService else { return }
        let consent = PrivacyConsent(
            policyVersion: PrivacyConsent.currentPolicyVersion,
            requiredProcessingAccepted: true,
            personalizationAccepted: personalization,
            locationPersonalizationAccepted: locationPersonalization,
            acceptedAt: privacyConsent.acceptedAt ?? .now
        )
        privacyConsent = consent
        persistPrivacyConsent(consent)
        if !personalization {
            profile = .empty
            UserDefaults.standard.removeObject(forKey: "saved-user-profile")
        }
        scheduleCloudReconciliation(delayNanoseconds: 0)
    }

    private static func loadPrivacyConsent() -> PrivacyConsent {
        guard let data = UserDefaults.standard.data(forKey: privacyConsentKey),
              let consent = try? JSONDecoder().decode(PrivacyConsent.self, from: data),
              consent.permitsService else { return .empty }
        return consent
    }

    private func persistPrivacyConsent(_ consent: PrivacyConsent) {
        guard let data = try? JSONEncoder().encode(consent) else { return }
        UserDefaults.standard.set(data, forKey: Self.privacyConsentKey)
    }

    /// 익명 Firebase 계정을 Apple 계정에 연결합니다. 이미 다른 기기에서 연결된 Apple 계정이면
    /// 해당 계정으로 로그인해 저장된 쿠폰을 불러옵니다. 원본 쿠폰 이미지는 기기 밖으로 이동하지 않습니다.
    func continueWithApple(idToken: String, rawNonce: String) async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw NSError(domain: "CouponCock.Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "로그인 서비스를 준비하지 못했어요."])
        }
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: nil)
        do {
            if let user = Auth.auth().currentUser, user.isAnonymous {
                let result = try await user.link(with: credential)
                firebaseUserID = result.user.uid
                refreshAccountStatus()
                await hydrateFirebaseData(uid: result.user.uid)
                return "이 기기의 쿠폰과 설정을 Apple 계정에 연결했어요."
            }
            let result = try await Auth.auth().signIn(with: credential)
            firebaseUserID = result.user.uid
            refreshAccountStatus()
            await hydrateFirebaseData(uid: result.user.uid)
            return "Apple 계정으로 로그인해 저장된 쿠폰과 설정을 불러왔어요."
        } catch {
            guard (error as NSError).code == AuthErrorCode.credentialAlreadyInUse.rawValue else { throw error }
            let result = try await Auth.auth().signIn(with: credential)
            firebaseUserID = result.user.uid
            refreshAccountStatus()
            await hydrateFirebaseData(uid: result.user.uid)
            return "기존 Apple 계정으로 로그인해 저장된 쿠폰과 설정을 불러왔어요."
        }
    }

    private func refreshAccountStatus() {
        guard FirebaseApp.app() != nil else {
            accountStatus = .unavailable
            return
        }
        guard let user = Auth.auth().currentUser else {
            accountStatus = .guest
            return
        }
        accountStatus = user.isAnonymous ? .guest : .apple
    }

    func saveImportedCoupon(_ coupon: Coupon) {
        pendingDeletedCouponIDs.remove(coupon.id)
        persistPendingDeletedCouponIDs()
        coupons.append(coupon)
        guard let encoded = try? JSONEncoder().encode(coupons) else { return }
        UserDefaults.standard.set(encoded, forKey: "saved-imported-coupons")
        scheduleCloudReconciliation()
    }

    func saveImportedCoupon(draft: CouponDraft, image: UIImage, barcode: CouponBarcodeCandidate? = nil) {
        let couponID = UUID().uuidString
        let imageFilename = try? CouponImageStore.shared.save(image: image, couponID: couponID)
        saveImportedCoupon(draft.makeCoupon(id: couponID, localImageFilename: imageFilename))
        if let barcode {
            try? SecureCouponBarcodeStore.save(barcode, couponID: couponID)
        }
    }

    func markCouponUsed(_ coupon: Coupon) {
        guard coupons.contains(coupon) else { return }
        pendingRestoredCouponIDs.remove(coupon.id)
        persistPendingRestoredCouponIDs()
        coupons.removeAll { $0.id == coupon.id }
        if !usedCoupons.contains(where: { $0.id == coupon.id }) {
            usedCoupons.insert(UsedCoupon(coupon: coupon, recommendation: recommendation, selectedOption: activeRecommendationOption), at: 0)
        }
        activeRecommendationOption = nil
        armCouponUseUndo(for: coupon)
        persistCouponCollections()
        scheduleCloudReconciliation()
    }

    func updateCoupon(_ updatedCoupon: Coupon) {
        guard let index = coupons.firstIndex(where: { $0.id == updatedCoupon.id }) else { return }
        coupons[index] = updatedCoupon
        coupons.sort { $0.expiresAt < $1.expiresAt }
        persistCouponCollections()
        scheduleCloudReconciliation(delayNanoseconds: 0)
    }

    /// Deletion remains reversible for five seconds; only then is the device-only image erased.
    func deleteCoupon(_ coupon: Coupon) {
        guard coupons.contains(coupon) else { return }
        clearCouponUseUndo()
        couponDeletionUndoExpirationTask?.cancel()
        coupons.removeAll { $0.id == coupon.id }
        pendingDeletedCouponIDs.insert(coupon.id)
        persistPendingDeletedCouponIDs()
        recentlyDeletedCoupon = coupon
        persistCouponCollections()
        scheduleCloudReconciliation(delayNanoseconds: 0)
        couponDeletionUndoExpirationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.recentlyDeletedCoupon?.id == coupon.id else { return }
            try? CouponImageStore.shared.delete(named: coupon.localImageFilename)
            SecureCouponBarcodeStore.delete(couponID: coupon.id)
            self.recentlyDeletedCoupon = nil
            self.couponDeletionUndoExpirationTask = nil
        }
    }

    func undoRecentCouponDeletion() -> Bool {
        guard let coupon = recentlyDeletedCoupon else { return false }
        couponDeletionUndoExpirationTask?.cancel()
        couponDeletionUndoExpirationTask = nil
        recentlyDeletedCoupon = nil
        pendingDeletedCouponIDs.remove(coupon.id)
        persistPendingDeletedCouponIDs()
        if !coupons.contains(where: { $0.id == coupon.id }) { coupons.append(coupon) }
        coupons.sort { $0.expiresAt < $1.expiresAt }
        persistCouponCollections()
        scheduleCloudReconciliation(delayNanoseconds: 0)
        return true
    }

    /// 5초 실행 취소와 사용 기록 화면의 수동 복원이 함께 사용하는 단일 복원 경로입니다.
    /// 원본 전체가 없는 레거시 기록은 잘못된 할인 조건을 추정하지 않고 복원을 거부합니다.
    @discardableResult
    func restoreUsedCoupon(_ usedCoupon: UsedCoupon) -> Bool {
        guard let coupon = usedCoupon.originalCoupon else { return false }
        return restoreCoupon(coupon)
    }

    @discardableResult
    func undoRecentCouponUse() -> Bool {
        guard let coupon = recentlyUsedCoupon else { return false }
        return restoreCoupon(coupon)
    }

    private func restoreCoupon(_ coupon: Coupon) -> Bool {
        guard usedCoupons.contains(where: { $0.id == coupon.id }) else {
            clearCouponUseUndo()
            return false
        }
        usedCoupons.removeAll { $0.id == coupon.id }
        if !coupons.contains(where: { $0.id == coupon.id }) {
            coupons.append(coupon)
            coupons.sort { $0.expiresAt < $1.expiresAt }
        }
        pendingRestoredCouponIDs.insert(coupon.id)
        persistPendingRestoredCouponIDs()
        clearCouponUseUndo()
        persistCouponCollections()
        // FirestoreRepository.save(coupon:) atomically restores the active document and
        // removes the used-history document. A failed request remains locally retryable.
        scheduleCloudReconciliation(delayNanoseconds: 0)
        return true
    }

    private func armCouponUseUndo(for coupon: Coupon) {
        couponUndoExpirationTask?.cancel()
        recentlyUsedCoupon = coupon
        couponUndoExpirationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.recentlyUsedCoupon = nil
            self?.couponUndoExpirationTask = nil
        }
    }

    private func clearCouponUseUndo() {
        couponUndoExpirationTask?.cancel()
        couponUndoExpirationTask = nil
        recentlyUsedCoupon = nil
    }

    private static func loadSavedCoupons() -> [Coupon] {
        guard let data = UserDefaults.standard.data(forKey: "saved-imported-coupons"),
              let coupons = try? JSONDecoder().decode([Coupon].self, from: data) else { return [] }
        return coupons.filter { $0.expiresAt > .now }
    }

    private static func loadSavedUsedCoupons() -> [UsedCoupon] {
        guard let data = UserDefaults.standard.data(forKey: "saved-used-coupons"),
              let coupons = try? JSONDecoder().decode([UsedCoupon].self, from: data) else { return [] }
        return coupons
    }

    private func persistCouponCollections() {
        if let encoded = try? JSONEncoder().encode(coupons) {
            UserDefaults.standard.set(encoded, forKey: "saved-imported-coupons")
        }
        if let encoded = try? JSONEncoder().encode(usedCoupons) {
            UserDefaults.standard.set(encoded, forKey: "saved-used-coupons")
        }
    }

    func setNearbyStores(_ stores: [Store]) {
        nearbyStores = stores
        storeDirectoryState = stores.isEmpty ? .empty : .live
    }

    func setStoreDirectoryState(_ state: StoreDirectoryState) {
        storeDirectoryState = state
    }

    func updateProfile(carrier: String, membershipGrade: String, monthlyBenefitStatus: UserProfile.MonthlyBenefitStatus, cards: [PaymentCard]) {
        guard privacyConsent.personalizationAccepted else { return }
        let updated = UserProfile(
            id: firebaseUserID ?? profile.id,
            carrier: carrier,
            membershipGrade: membershipGrade,
            monthlyBenefitStatus: monthlyBenefitStatus,
            cards: cards
        )
        profile = updated
        if let encoded = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(encoded, forKey: "saved-user-profile")
        }
        scheduleCloudReconciliation()
    }

    func retryCloudSync() {
        if firebaseUserID == nil {
            startFirebaseAuthenticationIfNeeded()
        } else {
            scheduleCloudReconciliation(delayNanoseconds: 0)
        }
    }

    /// Local data is the immediate source of truth on one anonymously authenticated device.
    /// Reconciliation is idempotent, so a partial Firestore failure can safely retry later.
    private func scheduleCloudReconciliation(delayNanoseconds: UInt64 = 350_000_000) {
        guard privacyConsent.permitsService else {
            cloudSyncState = .localOnly
            return
        }
        guard let uid = firebaseUserID else {
            cloudSyncState = firebaseReady ? .needsRetry : .localOnly
            return
        }
        cloudReconciliationTask?.cancel()
        cloudReconciliationTask = Task { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            cloudSyncState = .syncing
            let activeCoupons = coupons
            let history = usedCoupons
            let pendingRestoreIDs = pendingRestoredCouponIDs
            let pendingDeletionIDs = pendingDeletedCouponIDs
            do {
                try await FirestoreRepository.shared.save(consent: privacyConsent, uid: uid)
                if privacyConsent.personalizationAccepted {
                    try await FirestoreRepository.shared.save(profile: profile, uid: uid)
                } else {
                    try await FirestoreRepository.shared.clearPersonalization(uid: uid)
                }
                for couponID in pendingDeletionIDs {
                    try await FirestoreRepository.shared.delete(couponID: couponID, uid: uid)
                }
                for coupon in activeCoupons {
                    try await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
                for usedCoupon in history {
                    try await FirestoreRepository.shared.save(usedCoupon: usedCoupon, uid: uid)
                }
                guard !Task.isCancelled else { return }
                pendingRestoredCouponIDs.subtract(pendingRestoreIDs)
                persistPendingRestoredCouponIDs()
                pendingDeletedCouponIDs.subtract(pendingDeletionIDs)
                persistPendingDeletedCouponIDs()
                cloudSyncState = .synced
            } catch {
                guard !Task.isCancelled else { return }
                cloudSyncState = .needsRetry
                print("Firestore reconciliation unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// A user-controlled erase flow for beta and production. Cloud documents are deleted before
    /// the anonymous auth account so Firestore rules can still authorize the erase operation.
    func deleteAllPersonalData() async -> Bool {
        let uid = firebaseUserID
        do {
            cloudReconciliationTask?.cancel()
            await cloudReconciliationTask?.value
            cloudReconciliationTask = nil
            if let uid { try await FirestoreRepository.shared.deleteAllUserData(uid: uid) }
            if FirebaseApp.app() != nil, let user = Auth.auth().currentUser, uid == nil || user.uid == uid {
                try await user.delete()
                firebaseUserID = nil
                refreshAccountStatus()
            }
            try CouponImageStore.shared.deleteAll()
            SecureCouponBarcodeStore.deleteAll()
            UserDefaults.standard.removeObject(forKey: "saved-imported-coupons")
            UserDefaults.standard.removeObject(forKey: "saved-used-coupons")
            UserDefaults.standard.removeObject(forKey: "saved-user-profile")
            UserDefaults.standard.removeObject(forKey: Self.privacyConsentKey)
            UserDefaults.standard.removeObject(forKey: Self.notificationRecommendationContextKey)
            UserDefaults.standard.removeObject(forKey: Self.pendingRestoredCouponIDsKey)
            UserDefaults.standard.removeObject(forKey: Self.pendingDeletedCouponIDsKey)
            coupons = []
            usedCoupons = []
            pendingRestoredCouponIDs = []
            pendingDeletedCouponIDs = []
            clearCouponUseUndo()
            couponDeletionUndoExpirationTask?.cancel()
            recentlyDeletedCoupon = nil
            profile = .empty
            privacyConsent = .empty
            currentStore = nil
            recommendation = nil
            shouldShowRecommendation = false
            cloudSyncState = .localOnly
            return true
        } catch {
            print("Personal data deletion failed: \(error.localizedDescription)")
            return false
        }
    }

    func setCurrentStore(_ store: Store) {
        currentStore = store
    }

    func cacheRecommendation(_ recommendation: Recommendation, store: Store) {
        self.recommendation = recommendation
        activeRecommendationOption = recommendation.recommendedOption
        if let data = try? JSONEncoder().encode(
            NotificationRecommendationContext(store: store, recommendation: recommendation)
        ) {
            UserDefaults.standard.set(data, forKey: Self.notificationRecommendationContextKey)
        }
    }

    @discardableResult
    func restoreCachedRecommendation(for storeID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.notificationRecommendationContextKey),
              let context = try? JSONDecoder().decode(NotificationRecommendationContext.self, from: data),
              context.store.id == storeID else { return false }
        currentStore = context.store
        recommendation = context.recommendation
        activeRecommendationOption = context.recommendation.recommendedOption
        shouldShowRecommendation = true
        return true
    }

    func selectRecommendationOption(_ option: PriceOption) {
        activeRecommendationOption = option
    }

    private func hydrateFirebaseData(uid: String) async {
        do {
            let remote = try await FirestoreRepository.shared.loadUserData(uid: uid)
            if privacyConsent.personalizationAccepted, let profile = remote.profile {
                self.profile = profile
                if let encoded = try? JSONEncoder().encode(profile) {
                    UserDefaults.standard.set(encoded, forKey: "saved-user-profile")
                }
            }
            // An offline restore is locally authoritative until reconciliation atomically writes
            // the active document and removes its used-history counterpart in Firestore.
            let remoteHistory = remote.usedCoupons.filter { !pendingRestoredCouponIDs.contains($0.id) }
            let mergedUsedCoupons = Self.mergedUsedCoupons(Self.loadSavedUsedCoupons(), remoteHistory)
            usedCoupons = mergedUsedCoupons
            let usedCouponIDs = Set(mergedUsedCoupons.map(\.id))
            let localImportedCoupons = coupons

            if !remote.coupons.isEmpty {
                let localImages = Dictionary(uniqueKeysWithValues: coupons.compactMap { coupon in coupon.localImageFilename.map { (coupon.id, $0) } })
                let remoteCouponIDs = Set(remote.coupons.map(\.id))
                let remoteCoupons = remote.coupons.compactMap { coupon -> Coupon? in
                    guard !pendingDeletedCouponIDs.contains(coupon.id) else { return nil }
                    return Coupon(id: coupon.id, brand: coupon.brand, title: coupon.title, discountType: coupon.discountType,
                                  discountValue: coupon.discountValue, minimumOrderAmount: coupon.minimumOrderAmount,
                                  maximumDiscount: coupon.maximumDiscount,
                                  expiresAt: coupon.expiresAt, combinableWithCard: coupon.combinableWithCard,
                                  referencePrice: coupon.referencePrice,
                                  conditions: coupon.conditions, localImageFilename: localImages[coupon.id])
                }
                let unsyncedLocalCoupons = localImportedCoupons.filter { !remoteCouponIDs.contains($0.id) && !usedCouponIDs.contains($0.id) }
                coupons = (remoteCoupons + unsyncedLocalCoupons).filter { !usedCouponIDs.contains($0.id) }
                for coupon in unsyncedLocalCoupons {
                    try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
            } else {
                if privacyConsent.personalizationAccepted {
                    try? await FirestoreRepository.shared.save(profile: profile, uid: uid)
                }
                coupons.removeAll { usedCouponIDs.contains($0.id) }
                for coupon in coupons {
                    try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
            }
            persistCouponCollections()
            scheduleCloudReconciliation(delayNanoseconds: 0)
        } catch {
            // Local UserDefaults remains the offline fallback.
            cloudSyncState = .needsRetry
            print("Firestore sync unavailable: \(error.localizedDescription)")
        }
    }

    private static func loadSavedProfile() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: "saved-user-profile"),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else { return .empty }
        return profile.id == UserProfile.submission.id ? .empty : profile
    }

    private static func mergedUsedCoupons(_ collections: [UsedCoupon]...) -> [UsedCoupon] {
        var seenIDs = Set<String>()
        return collections
            .flatMap { $0 }
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.usedAt > $1.usedAt }
    }

    private static func loadPendingRestoredCouponIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingRestoredCouponIDsKey) ?? [])
    }

    private func persistPendingRestoredCouponIDs() {
        UserDefaults.standard.set(Array(pendingRestoredCouponIDs).sorted(), forKey: Self.pendingRestoredCouponIDsKey)
    }

    private static func loadPendingDeletedCouponIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingDeletedCouponIDsKey) ?? [])
    }

    private func persistPendingDeletedCouponIDs() {
        UserDefaults.standard.set(Array(pendingDeletedCouponIDs).sorted(), forKey: Self.pendingDeletedCouponIDsKey)
    }
}
