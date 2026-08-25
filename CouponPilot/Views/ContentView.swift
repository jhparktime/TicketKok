import SwiftUI
import UIKit
import CoreLocation
import PhotosUI
import AuthenticationServices

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var locationMonitor = LocationMonitor()
    @StateObject private var notificationManager = NotificationManager()
    @StateObject private var nearbyFranchiseFinder = NearbyFranchiseFinder()
    @State private var expectedPrice = "15000"
    @State private var selectedTab = AppState.captureInitialTab
    @State private var showCouponImporter = false
    @State private var selectedCarrier = UserProfile.empty.carrier
    @State private var selectedMembershipGrade = UserProfile.empty.membershipGrade
    @State private var selectedMonthlyBenefitStatus = UserProfile.empty.monthlyBenefitStatus
    @State private var selectedCardID = ""
    @State private var cardPreviousSpendQualified = false
    @State private var cardMonthlyBenefitRemaining = "0"
    @State private var showRecommendationError = false
    @State private var recommendationErrorTitle = "추천을 불러오지 못했어요"
    @State private var recommendationErrorMessage = "공공데이터 또는 인증된 API에 연결하지 못했습니다. 네트워크와 로그인 상태를 확인한 뒤 다시 시도해 주세요."
    @State private var failedRecommendationStore: Store?
    @State private var lastStoreDirectoryCoordinate: CLLocationCoordinate2D?
    @State private var lastStoreDirectoryRefreshAt = Date.distantPast
    @State private var isRefreshingStoreDirectory = false
    @State private var selectedRecommendationCoupon: Coupon?
    @State private var showDeletePersonalDataConfirmation = false
    @State private var personalDataDeletionMessage: String?
    @State private var showCardImporter = AppState.captureTarget == "card"
    @State private var appleSignInNonce = ""
    @State private var accountLoginMessage: String?
    @State private var showSupportSheet = false
    @State private var showNotificationSettings = false
    @State private var showSyncStatus = false
    @Namespace private var dockSelectionNamespace

    var body: some View {
        if appState.privacyConsent.permitsService {
            mainContent
        } else {
            PrivacyConsentView { personalization, locationPersonalization in
                appState.acceptPrivacyConsent(
                    personalization: personalization,
                    locationPersonalization: locationPersonalization
                )
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            selectedTabContent
                .id(selectedTab)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            floatingTabDock
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .tint(AppPalette.accent)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: selectedTab)
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let coupon = appState.recentlyUsedCoupon {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppPalette.accent)
                        Text("\(coupon.title) 사용 완료")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button("실행 취소") {
                            appState.undoRecentCouponUse()
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.55), lineWidth: 1) }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("실행 취소를 누르면 사용 가능한 쿠폰으로 복원합니다")
                }
                if let coupon = appState.recentlyDeletedCoupon {
                    HStack(spacing: 12) {
                        Image(systemName: "trash.circle.fill")
                        .foregroundStyle(AppPalette.warning)
                        Text("\(coupon.title) 삭제됨")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button("실행 취소") {
                            _ = appState.undoRecentCouponDeletion()
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.55), lineWidth: 1) }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("실행 취소를 누르면 삭제한 쿠폰을 복원합니다")
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 92)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.snappy, value: appState.recentlyUsedCoupon?.id)
        .animation(.snappy, value: appState.recentlyDeletedCoupon?.id)
        .onAppear {
            guard !AppState.isSubmissionSimulation else {
                if ["coupon-detail", "barcode"].contains(AppState.captureTarget), selectedRecommendationCoupon == nil {
                    selectedRecommendationCoupon = appState.coupons.first
                }
                handleNotificationTapIfNeeded()
                return
            }
            locationMonitor.onStoreEntry = { store in
                Task { await handleStoreEntry(store) }
            }
            locationMonitor.onLocationUpdate = { coordinate in
                Task { await refreshNearbyStores(at: coordinate) }
            }
            if appState.privacyConsent.locationPersonalizationAccepted {
                locationMonitor.resumeMonitoringIfEnabled()
            } else {
                locationMonitor.stopMonitoring()
            }
            handleNotificationTapIfNeeded()
        }
        .onChange(of: appState.privacyConsent.locationPersonalizationAccepted) { _, isAccepted in
            guard !AppState.isSubmissionSimulation else { return }
            if isAccepted {
                // Consent only unlocks a foreground location check. Background geofencing is a
                // separate, explicit choice in the location pill so iOS permission dialogs are
                // not stacked on first launch.
                locationMonitor.requestCurrentLocation()
            } else {
                locationMonitor.stopMonitoring()
            }
        }
        .onChange(of: notificationManager.pendingStoreID) { _, _ in
            handleNotificationTapIfNeeded()
        }
        .sheet(isPresented: $appState.shouldShowRecommendation) {
            if let recommendation = appState.recommendation {
                RecommendationSheet(
                    recommendation: recommendation,
                    canOpenCoupon: { option in
                        appState.coupons.contains(where: { $0.id == option.id })
                    },
                    onOpenCoupon: { option in
                        guard let coupon = appState.coupons.first(where: { $0.id == option.id }) else { return }
                        appState.selectRecommendationOption(option)
                        appState.shouldShowRecommendation = false
                        selectedRecommendationCoupon = coupon
                    }
                )
                    .presentationDetents([.large])
                    .presentationCornerRadius(34)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showCouponImporter) {
            CouponImportSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showCardImporter) {
            CardImportSheet { card in
                selectedCardID = card.productId
                cardPreviousSpendQualified = false
                cardMonthlyBenefitRemaining = "0"
            }
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportSheet()
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsSheet(notificationManager: notificationManager)
        }
        .sheet(isPresented: $showSyncStatus) {
            SyncStatusSheet()
                .environmentObject(appState)
        }
        .sheet(item: $selectedRecommendationCoupon) { coupon in
            NavigationStack {
                CouponDetailView(coupon: coupon)
            }
        }
        .alert(recommendationErrorTitle, isPresented: $showRecommendationError) {
            Button("다시 시도") {
                if let store = failedRecommendationStore {
                    Task { await requestRecommendation(for: store) }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(recommendationErrorMessage)
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case "coupons":
            NavigationStack { couponLibrary }
        case "history":
            NavigationStack { historyScreen }
        case "profile":
            NavigationStack { profileScreen }
        default:
            NavigationStack { homeScreen }
        }
    }

    private var floatingTabDock: some View {
        HStack(spacing: 6) {
            dockButton(tab: "home", title: "홈", icon: "house.fill")
            dockButton(tab: "coupons", title: "쿠폰", icon: "ticket.fill")
            dockButton(tab: "history", title: "기록", icon: "clock.fill")
            dockButton(tab: "profile", title: "내 정보", icon: "person.fill")
        }
        .padding(7)
        .background(.white, in: Capsule())
        .overlay { Capsule().stroke(AppPalette.border, lineWidth: 1) }
        .shadow(color: AppPalette.ink.opacity(0.08), radius: 14, y: 6)
    }

    private func dockButton(tab: String, title: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            guard selectedTab != tab else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                if isSelected {
                    Capsule()
                        .fill(AppPalette.blueChip)
                        .matchedGeometryEffect(id: "dock-selection", in: dockSelectionNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var homeScreen: some View {
        GeometryReader { proxy in
            ZStack {
                LiquidBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        topBar
                        if !AppState.isSubmissionSimulation {
                            locationPill
                        }
                        nearbyStoreHero
                        if !expiringCoupons.isEmpty { expiringCouponSection }
                        quickCouponSection
                        priceCard
                        usedCouponSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(LiquidBackground().ignoresSafeArea())
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isSimulatorAccountPreview ? "박재현님" : "내 계정")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .underline()
                Text(isSimulatorAccountPreview ? "Firebase 인증 완료" : syncStatusTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSimulatorAccountPreview ? AppPalette.accent : (appState.cloudSyncState == .needsRetry ? AppPalette.warning : AppPalette.muted))
            }
            Spacer()
            HStack(spacing: 18) {
                Button {
                    showSupportSheet = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel("도움말과 자주 묻는 질문")

                Button {
                    showNotificationSettings = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                        if notificationManager.authorizationStatus != .authorized,
                           notificationManager.authorizationStatus != .provisional {
                            Circle()
                                .fill(AppPalette.warning)
                                .frame(width: 7, height: 7)
                                .offset(x: 4, y: -5)
                        }
                    }
                }
                .accessibilityLabel("알림 설정")

                Button {
                    showSyncStatus = true
                } label: {
                    if syncStatusIcon == "iphone" {
                        DeviceSyncIcon()
                    } else {
                        Image(systemName: syncStatusIcon)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("동기화 상태")
            }
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(AppPalette.ink)
        }
        .padding(.top, 8)
    }

    private var syncStatusTitle: String {
        switch appState.cloudSyncState {
        case .localOnly: return "이 기기에 안전하게 저장 중"
        case .syncing: return "쿠폰을 안전하게 동기화 중"
        case .synced: return "쿠폰 동기화 완료"
        case .needsRetry: return "동기화 대기 · 탭하여 재시도"
        }
    }

    private var syncStatusIcon: String {
        if isSimulatorAccountPreview { return "checkmark.icloud.fill" }
        switch appState.cloudSyncState {
        case .localOnly: return "iphone"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.icloud.fill"
        case .needsRetry: return "icloud.slash.fill"
        }
    }

    private var locationPill: some View {
        HStack(spacing: 10) {
            Image(systemName: AppState.isSubmissionSimulation ? "checkmark.circle.fill" : (locationMonitor.monitoringState == .active ? "location.fill" : "location.circle"))
                .foregroundStyle(AppState.isSubmissionSimulation || locationMonitor.monitoringState == .active ? AppPalette.accent : AppPalette.accent)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("매장 진입 알림")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(locationStatusMessage)
                    .font(.caption)
                    .foregroundStyle(AppPalette.ink.opacity(0.58))
            }
            Spacer()
            if AppState.isSubmissionSimulation {
                Text("알림 준비됨")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            } else if locationMonitor.monitoringState == .needsAlwaysAuthorization {
                Button("백그라운드 설정") {
                    locationMonitor.requestBackgroundAuthorization()
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
            } else if locationMonitor.monitoringState == .active,
                      notificationManager.authorizationStatus != .authorized,
                      notificationManager.authorizationStatus != .provisional {
                Button("알림 허용") {
                    Task { await notificationManager.requestAuthorization() }
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
            } else {
                Toggle("매장 진입 알림", isOn: locationMonitoringBinding)
                    .labelsHidden()
                    .tint(AppPalette.accent)
                    .accessibilityHint("켜면 현재 위치 주변 매장 진입을 감지해 쿠폰을 추천합니다")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppPalette.border, lineWidth: 1) }
    }

    private var locationMonitoringBinding: Binding<Bool> {
        Binding(
            get: {
                locationMonitor.monitoringState == .active || locationMonitor.monitoringState == .requestingPermission
            },
            set: { enabled in
                if enabled {
                    guard appState.privacyConsent.locationPersonalizationAccepted else {
                        selectedTab = "profile"
                        return
                    }
                    locationMonitor.requestPermissionsAndMonitor(appState.nearbyStores)
                } else {
                    locationMonitor.stopMonitoring()
                }
            }
        )
    }

    private var locationStatusMessage: String {
        if AppState.isSubmissionSimulation { return "투썸플레이스 수원시청점 기준" }
        switch locationMonitor.monitoringState {
        case .denied: return "위치 권한이 필요해요"
        case .needsAlwaysAuthorization: return "백그라운드 알림은 ‘항상 허용’이 필요해요"
        case .active where locationMonitor.isAtRegionLimit:
            return "가까운 \(locationMonitor.availableStoreCount)곳 중 \(locationMonitor.monitoredStoreCount)곳 감지 중"
        default: return appState.storeDirectoryState.message
        }
    }

    private var nearbyStoreHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let store = appState.currentStore {
                let matchingCoupons = eligibleCoupons(for: store)
                VStack(alignment: .leading, spacing: 7) {
                    Label("가장 가까운 매장", systemImage: "location.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                    Text(store.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(matchingCoupons.isEmpty ? "이 매장에서 쓸 수 있는 혜택을 확인해 드릴게요" : "이 매장에서 쓸 수 있는 쿠폰과 멤버십 혜택을 찾아드릴게요")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppPalette.border, lineWidth: 1) }

                Button {
                    Task { await requestRecommendation(for: store) }
                } label: {
                    HStack(spacing: 8) {
                        if appState.isLoadingRecommendation {
                            ProgressView().tint(AppPalette.accent)
                        } else {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                        }
                        Text(appState.isLoadingRecommendation ? "혜택 계산 중" : matchingCoupons.isEmpty ? "매칭 쿠폰이 없어요" : storeRecommendationButtonTitle(for: store))
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(WooriPrimaryButtonStyle())
                .disabled(appState.isLoadingRecommendation || matchingCoupons.isEmpty)

            } else {
                Text(AppState.isSubmissionSimulation ? "투썸플레이스에서\n쿠폰을 비교해 볼까요?" : "매장에 들어가면\n혜택을 알려드릴게요")
                    .font(.system(size: 27, weight: .bold))
                    .lineSpacing(1)
                    .foregroundStyle(AppPalette.ink)

                if !AppState.isSubmissionSimulation {
                    Text(appState.storeDirectoryState.message)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }

            if !AppState.isSubmissionSimulation {
                Button {
                    if appState.privacyConsent.locationPersonalizationAccepted {
                        locationMonitor.requestCurrentLocation()
                    } else {
                        appState.updateOptionalConsents(
                            personalization: appState.privacyConsent.personalizationAccepted,
                            locationPersonalization: true
                        )
                    }
                } label: {
                        Label(
                            appState.privacyConsent.locationPersonalizationAccepted
                                ? (appState.storeDirectoryState == .unavailable ? "매장 목록 다시 불러오기" : "현재 위치 확인하기")
                                : "위치 개인화 동의하고 시작",
                            systemImage: "location.fill"
                        )
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(WooriPrimaryButtonStyle())
            }

            if !AppState.isSubmissionSimulation, locationMonitor.monitoringState == .denied {
                Button("설정에서 위치 권한 열기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            if AppState.isSubmissionSimulation {
                Button {
                    Task { await handleSubmissionStoreEntry() }
                } label: {
                    Label("투썸플레이스 수원시청점 혜택 보기", systemImage: "mappin.and.ellipse")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(WooriPrimaryButtonStyle())
                .accessibilityHint("가까운 투썸플레이스 매장의 쿠폰 혜택을 확인합니다")
            }

        }
        }
        .padding(.horizontal, 8)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private func storeRecommendationButtonTitle(for store: Store) -> String {
        if store.name.contains("투썸") { return "투썸 혜택 추천받기" }
        return "\(store.name) 혜택 추천받기"
    }

    private var quickCouponSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("쿠폰 미리보기")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button {
                    showCouponImporter = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("쿠폰 추가")
            }

            if appState.coupons.isEmpty {
                Button {
                    showCouponImporter = true
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "ticket.badge.plus")
                            .font(.title2)
                            .foregroundStyle(AppPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("첫 쿠폰을 등록해 보세요")
                                .font(.subheadline.weight(.bold))
                            Text("사진을 고르면 기기 내 OCR로 쿠폰 정보를 읽어요")
                                .font(.caption)
                                .foregroundStyle(AppPalette.ink.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.ink.opacity(0.42))
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppPalette.border, lineWidth: 1) }
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 12) {
                    ForEach(appState.coupons.prefix(3)) { coupon in
                        NavigationLink {
                            CouponDetailView(coupon: coupon)
                        } label: {
                            couponCard(coupon)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var expiringCoupons: [Coupon] {
        appState.coupons.filter { (0...7).contains($0.daysUntilExpiry) }.sorted { $0.expiresAt < $1.expiresAt }
    }

    private var expiringCouponSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("곧 만료되는 쿠폰", systemImage: "clock.badge.exclamationmark.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppPalette.warning)
                Spacer()
                Text("7일 이내")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.warning)
            }
            ForEach(expiringCoupons) { coupon in
                HStack(spacing: 12) {
                    BrandLogo(brand: coupon.brand, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(coupon.brand) \(coupon.title)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(coupon.daysUntilExpiry == 0 ? "오늘 만료" : "\(coupon.daysUntilExpiry)일 후 만료")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(coupon.discountType == .percentage ? "\(coupon.discountValue)%" : "−\(coupon.discountValue.formatted())원")
                        .font(.caption.weight(.bold)).foregroundStyle(AppPalette.warning)
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppPalette.warning.opacity(0.18), lineWidth: 1) }
            }
        }
    }

    private func couponCard(_ coupon: Coupon) -> some View {
        HStack(spacing: 16) {
            BrandLogo(brand: coupon.brand, size: 54)

            VStack(alignment: .leading, spacing: 7) {
                Text(coupon.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Text("\(coupon.brand) · \(coupon.expiresAt.formatted(date: .numeric, time: .omitted))까지")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                    Text(couponDisplayValue(coupon))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
            }
            Spacer(minLength: 6)
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .bold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(AppPalette.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppPalette.border, lineWidth: 1) }
    }

    private var priceCard: some View {
        WooriCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "wonsign.circle.fill")
                    .font(.title)
                    .foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("장바구니 결제금액")
                        .font(.system(size: 19, weight: .bold))
                    Text("단품 쿠폰은 상품 기준가로 별도 계산해요")
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                HStack(spacing: 3) {
                    TextField("15000", text: $expectedPrice)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.headline.weight(.bold))
                        .frame(width: 78)
                    Text("원").font(.caption).foregroundStyle(AppPalette.muted)
                }
            }
        }
    }

    private var usedCouponSection: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                selectedTab = "history"
            }
        } label: {
        HStack(spacing: 13) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(AppPalette.ink.opacity(0.45))
            VStack(alignment: .leading, spacing: 3) {
                Text("사용 완료 쿠폰 \(appState.usedCoupons.count)장")
                    .font(.subheadline.weight(.semibold))
                Text("이미 사용한 쿠폰은 추천에서 안전하게 제외돼요")
                    .font(.caption)
                    .foregroundStyle(AppPalette.ink.opacity(0.52))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.ink.opacity(0.42))
        }
        .padding(17)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppPalette.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityHint("사용 완료 쿠폰 기록을 엽니다")
    }

    private var couponLibrary: some View {
        List {
            Section("사용 가능한 쿠폰") {
                ForEach(appState.coupons) { coupon in
                    NavigationLink {
                        CouponDetailView(coupon: coupon)
                    } label: {
                        HStack(spacing: 13) {
                            BrandLogo(brand: coupon.brand, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(coupon.title).font(.headline)
                                Text("\(coupon.brand) · \(coupon.expiresAt.formatted(date: .abbreviated, time: .omitted))까지")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(couponListValue(coupon))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppPalette.accent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("내 쿠폰")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCouponImporter = true } label: {
                    Label("쿠폰 추가", systemImage: "plus")
                }
            }
        }
    }

    private func couponDisplayValue(_ coupon: Coupon) -> String {
        if coupon.discountValue == 0, let referencePrice = coupon.referencePrice {
            return "기준가 \(referencePrice.formatted())원"
        }
        return coupon.discountType == .percentage
            ? "최대 \(coupon.discountValue)% 할인"
            : "\(coupon.discountValue.formatted())원 할인"
    }

    private func couponListValue(_ coupon: Coupon) -> String {
        if coupon.discountValue == 0, let referencePrice = coupon.referencePrice {
            return "기준가 \(referencePrice.formatted())원"
        }
        return coupon.discountType == .percentage ? "\(coupon.discountValue)%" : "−\(coupon.discountValue.formatted())원"
    }

    private var historyScreen: some View {
        List {
            Section("사용 완료") {
                ForEach(appState.usedCoupons) { coupon in
                    NavigationLink {
                        UsedCouponDetailView(coupon: coupon)
                    } label: {
                        HStack(spacing: 13) {
                            if let image = CouponImageStore.shared.image(named: coupon.localImageFilename) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else if let resourceName = coupon.imageResourceName, let image = UIImage(named: resourceName) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(coupon.productName).font(.headline).lineLimit(1)
                                Text("\(coupon.brand) · \(coupon.usedAt.formatted(date: .abbreviated, time: .omitted)) 사용")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("사용 기록")
    }

    private var profileScreen: some View {
        Form {
            Section("계정") {
                if isSimulatorAccountPreview {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(AppPalette.blueChip)
                            Text("JH")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppPalette.accent)
                        }
                        .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("박재현님")
                                .font(.headline)
                            Label("Firebase 인증으로 로그인됨", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppPalette.accent)
                        }
                    }
                    Text("쿠폰과 개인 설정을 이 기기 계정으로 안전하게 관리하고 있어요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label(appState.accountStatus.title, systemImage: appState.accountStatus.isSignedIn ? "checkmark.icloud.fill" : "person.crop.circle.badge.clock")
                        .foregroundStyle(appState.accountStatus.isSignedIn ? AppPalette.accent : .primary)
                    Text(appState.accountStatus.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !isSimulatorAccountPreview, appState.accountStatus == .guest {
                    SignInWithAppleButton(.continue) { request in
                        let nonce = AppleSignInNonce.make()
                        appleSignInNonce = nonce
                        request.requestedScopes = [.email]
                        request.nonce = AppleSignInNonce.sha256(nonce)
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)

                    Text("로그인하면 이 기기의 쿠폰·프로필을 Apple 계정에 연결합니다. 카드번호·결제내역·위치 이력은 계정에 저장하지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("초개인화와 위치 동의") {
                Toggle("쿠폰·멤버십 초개인화", isOn: Binding(
                    get: { appState.privacyConsent.personalizationAccepted },
                    set: { accepted in
                        appState.updateOptionalConsents(
                            personalization: accepted,
                            locationPersonalization: appState.privacyConsent.locationPersonalizationAccepted
                        )
                    }
                ))
                Toggle("매장 진입 위치 개인화", isOn: Binding(
                    get: { appState.privacyConsent.locationPersonalizationAccepted },
                    set: { accepted in
                        appState.updateOptionalConsents(
                            personalization: appState.privacyConsent.personalizationAccepted,
                            locationPersonalization: accepted
                        )
                        if !accepted { locationMonitor.stopMonitoring() }
                    }
                ))
                Text("선택 동의이며 언제든 철회할 수 있어요. 개인화에는 최근 쿠폰 사용 횟수·간격과 만료 임박 집계만 사용하며, 가격 기준 1위와 비용 차이를 표시한 추천 우선순위를 제공할 수 있어요. 위치 이력, 카드번호·CVC·카드사 거래내역은 수집하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("통신사 멤버십") {
                Picker("통신사", selection: $selectedCarrier) {
                    ForEach(["SKT", "KT", "LG U+", "없음"], id: \.self) { Text($0).tag($0) }
                }
                Picker("멤버십 등급", selection: $selectedMembershipGrade) {
                    ForEach(["VVIP", "VIP", "GOLD", "SILVER", "일반", "확인 필요"], id: \.self) { Text($0).tag($0) }
                }
                Picker("이번 달 멤버십", selection: $selectedMonthlyBenefitStatus) {
                    ForEach(UserProfile.MonthlyBenefitStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
            }
            .disabled(!appState.privacyConsent.personalizationAccepted)
            Section("보유 카드 혜택 (선택)") {
                Button {
                    showCardImporter = true
                } label: {
                    Label("카드 사진으로 상품 찾기", systemImage: "viewfinder")
                }
                Picker("카드 상품", selection: $selectedCardID) {
                    Text("선택 안 함").tag("")
                    ForEach(PaymentCard.catalog) { card in
                        Text(card.productName).tag(card.productId)
                    }
                }
                if let card = selectedCatalogCard {
                    Toggle("전월 실적 충족", isOn: $cardPreviousSpendQualified)
                    TextField("이번 달 남은 할인 한도", text: $cardMonthlyBenefitRemaining)
                        .keyboardType(.numberPad)
                    Label("카드번호·유효기간·CVC·결제내역은 저장하지 않아요", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if card.productId == "shinhancard-mr-life" {
                        Text("오후 9시~오전 9시 식음료 10% · 1회 최대 1,000원. 쿠폰 중복은 제안하지 않아요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("현재는 공식 문서와 조건을 보여줘요. 결제수단·포인트 조건이 확정된 경우에만 가격 계산에 반영됩니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!appState.privacyConsent.personalizationAccepted)
            Section {
                Button("내 정보 저장") {
                    let cards = selectedCatalogCard.map { card in
                        [PaymentCard(
                            issuer: card.issuer,
                            productId: card.productId,
                            productName: card.productName,
                            previousMonthSpendQualified: cardPreviousSpendQualified,
                            monthlyBenefitRemainingAmount: max(0, Int(cardMonthlyBenefitRemaining) ?? 0)
                        )]
                    } ?? []
                    appState.updateProfile(
                        carrier: selectedCarrier,
                        membershipGrade: selectedMembershipGrade,
                        monthlyBenefitStatus: selectedMonthlyBenefitStatus,
                        cards: cards
                    )
                }
                .fontWeight(.semibold)
                .disabled(!appState.privacyConsent.personalizationAccepted)
            }
            Section("개인정보") {
                Text("쿠폰 이미지와 쿠폰·프로필·사용 기록, 로그인 계정을 삭제할 수 있어요. 결제정보는 수집하지 않고, OCR 텍스트는 AI 구조화 요청에만 전송합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("계정 및 모든 데이터 삭제", role: .destructive) {
                    showDeletePersonalDataConfirmation = true
                }
            }
            Section("기타 안내") {
                DisclosureGroup("브랜드 표지 안내") {
                    Text("쿠폰 사용처의 브랜드명·표지는 서로 다른 프랜차이즈를 정확히 구분하고 오사용을 방지하기 위한 식별 정보로 최소한의 범위에서 표시합니다. 별도 표시가 없는 한 해당 브랜드와의 제휴·보증을 의미하지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("내 정보")
        // The tab dock is an overlay, so the final legal/brand disclosure must be able to
        // scroll entirely above it on compact iPhone screens.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 116)
        }
        .onAppear {
            selectedCarrier = appState.profile.carrier
            selectedMembershipGrade = appState.profile.membershipGrade
            selectedMonthlyBenefitStatus = appState.profile.monthlyBenefitStatus
            if let card = appState.profile.cards.first {
                selectedCardID = card.productId
                cardPreviousSpendQualified = card.previousMonthSpendQualified
                cardMonthlyBenefitRemaining = String(card.monthlyBenefitRemainingAmount)
            }
        }
        .confirmationDialog("계정과 모든 데이터를 삭제할까요?", isPresented: $showDeletePersonalDataConfirmation, titleVisibility: .visible) {
            Button("모두 삭제", role: .destructive) {
                Task {
                    let completed = await appState.deleteAllPersonalData()
                    personalDataDeletionMessage = completed ? "계정과 이 기기·클라우드의 쿠폰·프로필·사용 기록을 삭제했어요." : "일부 데이터를 삭제하지 못했어요. Apple 로그인 계정은 최근 로그인 확인이 필요할 수 있어요."
                }
            }
        } message: {
            Text("로그인 계정, 이 기기의 쿠폰 이미지, 클라우드에 동기화된 쿠폰·프로필·사용 기록이 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .alert("데이터 삭제", isPresented: Binding(get: { personalDataDeletionMessage != nil }, set: { if !$0 { personalDataDeletionMessage = nil } })) {
            Button("확인", role: .cancel) { personalDataDeletionMessage = nil }
        } message: {
            Text(personalDataDeletionMessage ?? "")
        }
        .alert("로그인", isPresented: Binding(get: { accountLoginMessage != nil }, set: { if !$0 { accountLoginMessage = nil } })) {
            Button("확인", role: .cancel) { accountLoginMessage = nil }
        } message: {
            Text(accountLoginMessage ?? "")
        }
    }

    private var isSimulatorAccountPreview: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        guard case let .success(authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              !appleSignInNonce.isEmpty else {
            if case let .failure(error) = result { accountLoginMessage = error.localizedDescription }
            else { accountLoginMessage = "Apple 로그인 정보를 확인하지 못했어요. 다시 시도해 주세요." }
            return
        }
        Task {
            do {
                accountLoginMessage = try await appState.continueWithApple(idToken: idToken, rawNonce: appleSignInNonce)
            } catch {
                accountLoginMessage = "Apple 로그인에 실패했어요. Firebase Authentication에서 Apple 제공업체가 활성화됐는지 확인해 주세요."
            }
            appleSignInNonce = ""
        }
    }

    private var selectedCatalogCard: PaymentCard? {
        PaymentCard.catalog.first { $0.productId == selectedCardID }
    }

    @discardableResult
    private func requestRecommendation(for store: Store, presentsFailureAlert: Bool = true) async -> Recommendation? {
        let matchingCoupons = eligibleCoupons(for: store)
        guard !matchingCoupons.isEmpty else { return nil }
        if AppState.isSubmissionSimulation {
            let recommendation = Recommendation.submissionPreview(for: store)
            appState.cacheRecommendation(recommendation, store: store)
            appState.shouldShowRecommendation = true
            return recommendation
        }
        guard await appState.ensureFirebaseAuthentication() else {
            if presentsFailureAlert {
                presentRecommendationError(
                    for: store,
                    title: "보안 연결을 준비하지 못했어요",
                    message: "Firebase 익명 로그인이 아직 준비되지 않았습니다. 네트워크와 Firebase 설정을 확인한 뒤 다시 시도해 주세요."
                )
            }
            return nil
        }
        appState.isLoadingRecommendation = true
        defer { appState.isLoadingRecommendation = false }
        let price = Int(expectedPrice) ?? 15_000
        do {
            let recommendationProfile = appState.privacyConsent.personalizationAccepted ? appState.profile : .empty
            let recommendation = try await AgentAPIService().fetchRecommendation(
                for: store,
                expectedPrice: price,
                profile: recommendationProfile,
                coupons: matchingCoupons,
                personalization: appState.recommendationPersonalizationContext
            )
            appState.cacheRecommendation(recommendation, store: store)
            appState.shouldShowRecommendation = true
            return recommendation
        } catch {
            if presentsFailureAlert {
                presentRecommendationError(
                    for: store,
                    title: "실시간 추천을 불러오지 못했어요",
                    message: "인증된 추천 API 또는 공공 매장 데이터 연결을 확인해 주세요."
                )
            }
            return nil
        }
    }

    private func presentRecommendationError(for store: Store, title: String, message: String) {
        failedRecommendationStore = store
        recommendationErrorTitle = title
        recommendationErrorMessage = message
        showRecommendationError = true
    }

    private func handleStoreEntry(_ store: Store) async {
        appState.setCurrentStore(store)
        let matchingCoupons = eligibleCoupons(for: store)
        guard !matchingCoupons.isEmpty else { return }
        // The first alert is intentionally independent of backend latency. If a temporary API
        // failure happens in the background, the customer still receives a useful store-entry
        // notification instead of losing the core service moment.
        await notificationManager.notifyStoreEntry(store, couponCount: matchingCoupons.count)
        guard let recommendation = await requestRecommendation(for: store, presentsFailureAlert: false) else { return }
        // Do not send a second banner when the calculation completes. The first notification
        // already opens the cached recommendation through its storeID deep-link context.
        _ = recommendation
    }

    private func handleSubmissionStoreEntry() async {
        let store = Store.suwonSubmissionTwosome
        appState.setCurrentStore(store)
        let matchingCoupons = eligibleCoupons(for: store)
        // This is an explicit test action, so requesting alert permission here does not compete
        // with the first-run location permission flow.
        await notificationManager.requestAuthorization()
        await notificationManager.notifyStoreEntry(store, couponCount: matchingCoupons.count)
        guard let recommendation = await requestRecommendation(for: store, presentsFailureAlert: false) else { return }
        _ = recommendation
    }

    private func handleNotificationTapIfNeeded() {
        guard let storeID = notificationManager.consumePendingStoreID() else { return }
        selectedTab = "home"
        if appState.restoreCachedRecommendation(for: storeID) { return }
        if let store = appState.nearbyStores.first(where: { $0.id == storeID }) {
            appState.setCurrentStore(store)
            Task { await requestRecommendation(for: store) }
        }
    }

    private func eligibleCoupons(for store: Store) -> [Coupon] {
        appState.coupons.filter { $0.isActive && $0.matches(store: store) }
    }

    private func refreshNearbyStores(at coordinate: CLLocationCoordinate2D) async {
        guard KoreaScope.contains(coordinate) else { return }
        guard !isRefreshingStoreDirectory else { return }
        if let previous = lastStoreDirectoryCoordinate {
            let movedMeters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            let refreshedRecently = Date.now.timeIntervalSince(lastStoreDirectoryRefreshAt) < 120
            // Core Location can report many nearly identical points. The backend already caches
            // each area, and this guard avoids unnecessary authenticated API calls on the device.
            if refreshedRecently && movedMeters < 250 { return }
        }
        isRefreshingStoreDirectory = true
        defer { isRefreshingStoreDirectory = false }
        lastStoreDirectoryCoordinate = coordinate
        lastStoreDirectoryRefreshAt = .now
        appState.setStoreDirectoryState(.loading)

        let couponFranchises = Array(Set(appState.coupons.compactMap { SupportedFranchise.detected(in: $0.brand) }))
        let localStores = await nearbyFranchiseFinder.findStores(near: coordinate, franchises: couponFranchises)
        // Register local Apple Maps matches immediately. The public-data response below then
        // enriches the directory without making the user wait before geofencing begins.
        if !localStores.isEmpty {
            appState.setNearbyStores(localStores)
            locationMonitor.replaceMonitoredStores(localStores)
        }
        do {
            guard await appState.ensureFirebaseAuthentication() else { throw URLError(.userAuthenticationRequired) }
            let publicStores = try await AgentAPIService().fetchNearbyStores(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let stores = mergedStores(primary: localStores, secondary: publicStores, near: coordinate)
            appState.setNearbyStores(stores)
            locationMonitor.replaceMonitoredStores(stores)
        } catch {
            // MapKit results remain useful when the public directory is temporarily unavailable.
            if localStores.isEmpty {
                appState.setStoreDirectoryState(.unavailable)
                locationMonitor.replaceMonitoredStores([])
            }
        }
    }

    private func mergedStores(primary: [Store], secondary: [Store], near coordinate: CLLocationCoordinate2D) -> [Store] {
        var seen = Set<String>()
        return (primary + secondary).sorted {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            < CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        }.filter { store in
            let coordinateKey = String(format: "%.4f-%.4f", store.latitude, store.longitude)
            return seen.insert(coordinateKey).inserted
        }
    }
}

private struct SupportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("쿠폰콕 사용 방법") {
                    Label("쿠폰 등록", systemImage: "camera.viewfinder")
                    Text("쿠폰 사진을 등록하면 iPhone에서 텍스트와 바코드를 읽어 필요한 정보만 저장합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("매장 진입 알림", systemImage: "location.fill")
                    Text("위치와 알림을 허용하면 가까운 매장에 도착했을 때 사용 가능한 쿠폰을 알려드립니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("추천 결과", systemImage: "calculator")
                    Text("최종가와 절약액은 Calculator Tool이 계산하고, AI는 확인된 근거를 바탕으로 이유를 설명합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("개인정보") {
                    Text("쿠폰 원본 이미지와 실제 교환 바코드는 이 iPhone에만 보관됩니다.")
                        .font(.footnote)
                }
            }
            .navigationTitle("도움말")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct NotificationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var notificationManager: NotificationManager

    private var statusDescription: String {
        switch notificationManager.authorizationStatus {
        case .authorized, .provisional: return "매장 진입 시 쿠폰 추천 알림을 받을 수 있어요."
        case .denied: return "알림이 꺼져 있어요. 설정에서 쿠폰콕 알림을 허용해 주세요."
        default: return "알림을 허용하면 매장에 도착했을 때 쿠폰 추천을 알려드려요."
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: notificationManager.authorizationStatus == .authorized || notificationManager.authorizationStatus == .provisional ? "bell.badge.fill" : "bell.slash.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(AppPalette.accent)
                Text("매장 진입 알림")
                    .font(.title3.weight(.bold))
                Text(statusDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if notificationManager.authorizationStatus == .denied {
                    Button("설정에서 알림 켜기") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.accent)
                } else if notificationManager.authorizationStatus != .authorized,
                          notificationManager.authorizationStatus != .provisional {
                    Button("알림 허용") {
                        Task { await notificationManager.requestAuthorization() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.accent)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("알림")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SyncStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    private var title: String {
        switch appState.cloudSyncState {
        case .localOnly: return "이 기기에 안전하게 저장 중"
        case .syncing: return "쿠폰을 동기화하고 있어요"
        case .synced: return "쿠폰 동기화 완료"
        case .needsRetry: return "동기화가 필요해요"
        }
    }

    private var icon: String {
        switch appState.cloudSyncState {
        case .localOnly: return "iphone"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.icloud.fill"
        case .needsRetry: return "icloud.slash.fill"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 46))
                    .foregroundStyle(appState.cloudSyncState == .needsRetry ? AppPalette.warning : AppPalette.accent)
                Text(title)
                    .font(.title3.weight(.bold))
                Text("쿠폰과 프로필 정보는 로그인한 계정과 동기화됩니다. 쿠폰 원본 이미지와 실제 바코드는 이 iPhone에만 보관됩니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if appState.cloudSyncState == .needsRetry {
                    Button("동기화 다시 시도") { appState.retryCloudSync() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppPalette.accent)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("동기화")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct DeviceSyncIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .stroke(AppPalette.ink, lineWidth: 2.2)
                }
                .frame(width: 15, height: 24)
            VStack(spacing: 0) {
                Capsule()
                    .fill(AppPalette.ink)
                    .frame(width: 5, height: 1.5)
                Spacer(minLength: 0)
                Capsule()
                    .fill(AppPalette.ink.opacity(0.55))
                    .frame(width: 5, height: 1.3)
            }
            .frame(width: 15, height: 18)
        }
        .frame(width: 24, height: 28)
    }
}

private struct PrivacyConsentView: View {
    @State private var requiredProcessingAccepted = false
    @State private var personalizationAccepted = false
    @State private var locationPersonalizationAccepted = false
    let onContinue: (Bool, Bool) -> Void

    var body: some View {
        ZStack {
            LiquidBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                        .frame(width: 74, height: 74)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Text("쿠폰콕을 시작하기 전에")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("서비스에 꼭 필요한 처리와 선택 가능한 초개인화 항목을 분리해 안내해요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    consentCard(
                        title: "필수 개인정보 처리",
                        detail: "익명 사용자 ID, 확인한 쿠폰 정보, 사용 기록을 계정 동기화와 추천 제공에 사용합니다. 쿠폰 원본 이미지는 iPhone에만 보관하며, 쿠폰 문구를 AI로 정리할 때는 민감정보를 가린 텍스트만 전송합니다.",
                        isOn: $requiredProcessingAccepted,
                        required: true
                    )
                    consentCard(
                        title: "쿠폰·멤버십 초개인화",
                        detail: "보유 쿠폰, 통신사·등급, 카드 상품명과 사용 처리한 쿠폰의 브랜드·사용 시점·확인된 최종가를 이용합니다. 최근 180일의 브랜드별 횟수·사용 간격과 만료 임박 집계로 추천 우선순위를 조정할 수 있으며, 가격 기준 1위와의 차이를 항상 표시합니다. 카드번호와 카드사 거래내역은 수집하지 않습니다.",
                        isOn: $personalizationAccepted,
                        required: false
                    )
                    consentCard(
                        title: "매장 진입 위치 개인화",
                        detail: "iOS가 현재 위치 주변의 지원 매장 진입을 감지해 알림을 보냅니다. 위치 이력과 이동 경로는 서버에 저장하지 않습니다.",
                        isOn: $locationPersonalizationAccepted,
                        required: false
                    )

                    Label("Calculator는 금액·절약액·가격 기준 순위를 확정합니다. 개인화는 동의된 집계로만 추천 표시 우선순위를 조정하며, 최대 절약안은 항상 함께 보여줍니다.", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        onContinue(personalizationAccepted, locationPersonalizationAccepted)
                    } label: {
                        Text("동의하고 시작하기")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.accent)
                    .disabled(!requiredProcessingAccepted)

                    Text("선택 동의를 거부해도 쿠폰을 직접 등록·관리할 수 있으며, 내 정보에서 언제든 변경할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
        }
    }

    private func consentCard(title: String, detail: String, isOn: Binding<Bool>, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Text(required ? "필수" : "선택")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(required ? AppPalette.warning : AppPalette.accent)
                    Text(title).font(.headline)
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(17)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white, lineWidth: 1) }
    }
}

@MainActor
private struct CardImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var frontItem: PhotosPickerItem?
    @State private var backItem: PhotosPickerItem?
    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?
    @State private var localRecognition: CardRecognitionResult?
    @State private var multimodalRecognition: CardMultimodalRecognition?
    @State private var allowGeminiCloudAnalysis = false
    @State private var captureSide: CardPhotoSide?
    @State private var showCamera = false
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    let onUseCard: (PaymentCard) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title3)
                                .foregroundStyle(AppPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("카드 원본은 저장하지 않아요")
                                    .font(.headline)
                                Text("사진은 이 iPhone에서만 읽고 인식이 끝나면 메모리에서 제거합니다.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Text("카드번호·유효기간·CVC·바코드는 즉시 마스킹·폐기하며, 카드사·상품명과 직접 입력한 혜택 상태만 저장합니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.white.opacity(0.82))

                Section {
                    PhotosPicker(selection: $frontItem, matching: .images) {
                        CardPhotoSelectionRow(
                            title: "카드 앞면",
                            subtitle: frontImage == nil ? "상품명 인식에 사용해요" : "사진 선택 완료",
                            systemImage: "creditcard.fill",
                            isComplete: frontImage != nil
                        )
                    }
                    .buttonStyle(.plain)
                    PhotosPicker(selection: $backItem, matching: .images) {
                        CardPhotoSelectionRow(
                            title: "카드 뒷면 · 선택",
                            subtitle: backImage == nil ? "기기 내 OCR 보조용이에요" : "사진 선택 완료",
                            systemImage: "rectangle.and.paperclip",
                            isComplete: backImage != nil
                        )
                    }
                    .buttonStyle(.plain)
                    if frontImage != nil || backImage != nil {
                        Label("\(frontImage == nil ? "앞면 미선택" : "앞면 선택 완료") · \(backImage == nil ? "뒷면 미선택" : "뒷면 선택 완료")", systemImage: "checkmark.rectangle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppPalette.accent)
                    }
                    HStack {
                        Button { beginCameraCapture(.front) } label: {
                            Label("앞면 촬영", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button { beginCameraCapture(.back) } label: {
                            Label("뒷면 촬영", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("앞면만으로도 기기 내 인식을 시작할 수 있어요. 뒷면은 선택 사항이며 기기 밖으로 전송하지 않아요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("카드 사진 등록")
                        Text("앞면부터 선택해 주세요")
                            .textCase(nil)
                            .font(.caption)
                    }
                }
                .listRowBackground(Color.white.opacity(0.82))

                if frontImage != nil, backImage != nil {
                    Section("기기 내 확인") {
                        Button {
                            Task { await recognizeOnDevice() }
                        } label: {
                            Label("기기에서 카드 상품 찾기", systemImage: "iphone.and.arrow.forward")
                        }
                        if let card = localRecognition?.card {
                            Label("후보: \(card.productName)", systemImage: "checkmark.seal")
                                .foregroundStyle(AppPalette.accent)
                        } else if localRecognition != nil {
                            Text("기기 내 OCR만으로는 상품을 확정하지 못했어요.")
                                .font(.footnote)
                                .foregroundStyle(AppPalette.warning)
                        }
                        if localRecognition?.sensitiveNumberDetectedAndIgnored == true {
                            Label("긴 숫자열은 감지 즉시 폐기했어요.", systemImage: "eye.slash.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Gemini 카드 상품 확인 (선택)") {
                        Toggle("마스킹된 앞면 시각 정보와 OCR을 Gemini에 1회 전송", isOn: $allowGeminiCloudAnalysis)
                        Text("동의하면 뒷면은 iPhone 안에서만 OCR 처리합니다. 앞면은 기기에서 모든 텍스트와 하단 민감 영역을 픽셀 마스킹하고 Vision 재검사를 통과한 시각 정보만 전송합니다. 서버는 DLP로 모든 텍스트를 한 번 더 가린 결과만 Gemini에 전달하며, 원본 카드 사진·카드번호·유효기간·CVC·바코드는 저장·로그·Gemini 전송하지 않습니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await recognizeWithGemini() }
                        } label: {
                            Label("Gemini로 상품·공식 혜택 확인", systemImage: "sparkles")
                        }
                        .disabled(!allowGeminiCloudAnalysis || !appState.privacyConsent.personalizationAccepted || isAnalyzing)
                        if !appState.privacyConsent.personalizationAccepted {
                            Text("내 정보의 ‘쿠폰·멤버십 초개인화’ 선택 동의 후 사용할 수 있어요.")
                                .font(.footnote)
                                .foregroundStyle(AppPalette.warning)
                        }
                    }

                    if isAnalyzing { ProgressView("기기에서 카드 상품을 확인하는 중") }
                    if let recognition = multimodalRecognition, let card = recognition.card {
                        Section("사용자 확인 후 저장") {
                            Label("Gemini 후보: \(card.productName)", systemImage: recognition.needsManualSelection ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .foregroundStyle(recognition.needsManualSelection ? AppPalette.warning : AppPalette.accent)
                            Text(recognition.needsManualSelection ? "확신도가 낮거나 확인이 필요한 결과예요. 카드 실물을 보고 상품명이 맞는지 확인해 주세요." : "카드 실물의 상품명이 맞는지 확인한 뒤 저장해 주세요.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("이 카드 상품으로 입력") {
                                onUseCard(card)
                                clearSensitiveImagesAndDismiss()
                            }
                            .fontWeight(.semibold)
                        }
                    } else if multimodalRecognition != nil {
                        Section("사용자 확인 필요") {
                            Text("지원하는 카드 상품을 확실하게 찾지 못했어요. 원본 사진은 저장하지 않았고, 이전 화면에서 직접 선택해 주세요.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let recognition = multimodalRecognition, !recognition.benefitSources.isEmpty {
                        Section("공식 혜택 확인") {
                            ForEach(recognition.benefitSources) { source in
                                Link(destination: URL(string: source.sourceURL)!) {
                                    Label(source.title, systemImage: "link")
                                }
                                Text(source.limitations)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("지원 카드 상품") {
                    ForEach(PaymentCard.catalog) { card in
                        Label(card.productName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppPalette.ink)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppPalette.topCanvas)
            .navigationTitle("카드 혜택 등록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { clearSensitiveImagesAndDismiss() } } }
            .onChange(of: frontItem) { _, item in
                Task { frontImage = await loadImage(from: item) }
            }
            .onChange(of: backItem) { _, item in
                Task { backImage = await loadImage(from: item) }
            }
            .sheet(isPresented: $showCamera) {
                CardCameraPicker { image in
                    switch captureSide {
                    case .front: frontImage = image
                    case .back: backImage = image
                    case nil: break
                    }
                    captureSide = nil
                }
            }
            .onDisappear {
                // The picker can retain selected photo identifiers, so explicitly release all
                // in-memory image and safe-payload references as soon as this sheet closes.
                frontImage = nil
                backImage = nil
                frontItem = nil
                backItem = nil
            }
        }
    }

    private func loadImage(from item: PhotosPickerItem?) async -> UIImage? {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: data)
    }

    private func beginCameraCapture(_ side: CardPhotoSide) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "이 기기에서는 카메라를 사용할 수 없어요. 사진 보관함에서 앞·뒷면을 선택해 주세요."
            return
        }
        captureSide = side
        showCamera = true
    }

    @MainActor
    private func recognizeOnDevice() async {
        guard let frontImage else { return }
        isAnalyzing = true
        localRecognition = nil
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            // The local matcher uses the front as a conservative fallback. The back is used only
            // by the later privacy-preserving Gemini payload preparation.
            localRecognition = try await CouponOCRService().recognizeCardProduct(in: frontImage)
        } catch {
            errorMessage = "카드 이미지를 읽지 못했어요. 다른 사진을 선택하거나 직접 입력해 주세요."
        }
    }

    @MainActor
    private func recognizeWithGemini() async {
        guard allowGeminiCloudAnalysis, let frontImage, let backImage else { return }
        isAnalyzing = true
        multimodalRecognition = nil
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            let payload = try await CouponOCRService().prepareSafeCardRecognitionPayload(front: frontImage, back: backImage)
            multimodalRecognition = try await AgentAPIService().recognizeCardProduct(payload)
        } catch OCRServiceError.noNonSensitiveCardIdentity {
            errorMessage = "민감정보를 제외하면 카드 상품을 확인할 텍스트가 없어요. 이전 화면에서 직접 선택해 주세요."
        } catch {
            errorMessage = "Gemini 카드 확인을 완료하지 못했어요. 카드 이미지는 저장하지 않았으며, 직접 선택할 수 있어요."
        }
    }

    private func clearSensitiveImagesAndDismiss() {
        frontImage = nil
        backImage = nil
        frontItem = nil
        backItem = nil
        dismiss()
    }
}

private enum CardPhotoSide {
    case front
    case back
}

private struct CardPhotoSelectionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : systemImage)
                .font(.title3)
                .foregroundStyle(isComplete ? AppPalette.accent : .blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct CardCameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CardCameraPicker
        init(parent: CardCameraPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }
    }
}

private struct LiquidBackground: View {
    var body: some View {
        LinearGradient(
            colors: [AppPalette.topCanvas, AppPalette.canvas],
            startPoint: .top,
            endPoint: .bottom
        )
            .ignoresSafeArea()
    }
}

struct BrandLogo: View {
    let brand: String
    let size: CGFloat

    private var franchise: SupportedFranchise? {
        SupportedFranchise.detected(in: brand)
    }

    private var visualScale: CGFloat {
        switch franchise {
        case .starbucks: 1.18
        case .baskinrobbins: 1.82
        case .twosome: 1.56
        case .parisbaguette: 1.08
        case .touslesjours: 1.06
        case .ediya: 1.42
        case .ashleyqueens: 1.20
        case .hollys: 1.48
        case .mega, .compose, .paiks, .coffeebean, .gongcha, .theventi: 1.08
        case .cu, .gs25, .seveneleven, .emart24: 1
        default: 1
        }
    }

    var body: some View {
        ZStack {
            if franchise == nil {
                Image(systemName: "ticket.fill")
                    .font(.system(size: size * 0.40, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.couponBlue, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                logoImage
                    .frame(width: size * 0.68, height: size * 0.68)
                    .scaleEffect(visualScale)
                    .frame(width: size, height: size)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .background {
            if franchise != nil {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.white)
            }
        }
        .overlay {
            if franchise != nil {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(AppPalette.border, lineWidth: 1)
            }
        }
        .accessibilityLabel("\(brand) 로고")
    }

    @ViewBuilder
    private var logoImage: some View {
        switch franchise {
        case .starbucks:
            Image("BrandStarbucks").resizable().scaledToFit()
        case .baskinrobbins:
            Image("BrandBaskinRobbins").resizable().scaledToFit()
        case .twosome:
            Image("BrandTwosomePlace").resizable().scaledToFit()
        case .parisbaguette:
            Image("BrandParisBaguette").resizable().scaledToFit()
        case .touslesjours:
            Image("BrandTousLesJours").resizable().scaledToFit()
        case .ediya:
            Image("BrandEdiya")
                .resizable()
                .scaledToFit()
                .colorInvert()
                .luminanceToAlpha()
                .foregroundStyle(Color(red: 0.04, green: 0.28, blue: 0.56))
        case .ashleyqueens:
            Image("BrandAshleyQueens")
                .resizable()
                .scaledToFit()
                .colorInvert()
                .luminanceToAlpha()
                .foregroundStyle(AppPalette.ink)
        case .hollys:
            Image("BrandHollysCoffee").resizable().scaledToFit()
        case .mega:
            Image("BrandMegaMGC").resizable().scaledToFit()
        case .compose:
            Image("BrandComposeCoffee").resizable().scaledToFit()
        case .paiks:
            Image("BrandPaiksCoffee").resizable().scaledToFit()
        case .coffeebean:
            Image("BrandCoffeeBean").resizable().scaledToFit()
        case .gongcha:
            Image("BrandGongCha").resizable().scaledToFit()
        case .theventi:
            Image("BrandTheVenti").resizable().scaledToFit()
        case .cu:
            ConvenienceBrandMark(label: "CU", color: Color(red: 0.43, green: 0.16, blue: 0.67))
        case .gs25:
            ConvenienceBrandMark(label: "GS25", color: Color(red: 0.00, green: 0.42, blue: 0.28))
        case .seveneleven:
            ConvenienceBrandMark(label: "7", color: Color(red: 0.00, green: 0.42, blue: 0.30))
        case .emart24:
            ConvenienceBrandMark(label: "24", color: Color(red: 0.72, green: 0.45, blue: 0.00))
        default:
            EmptyView()
        }
    }
}

private struct ConvenienceBrandMark: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 17, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .minimumScaleFactor(0.55)
            .lineLimit(1)
    }
}

private struct WooriCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppPalette.border, lineWidth: 1) }
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1) }
            .shadow(color: AppPalette.ink.opacity(0.06), radius: 12, y: 6)
    }
}

private struct WooriPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppPalette.accent.opacity(0.14), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct PrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppPalette.ink)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.68), AppPalette.accent.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(Capsule())
                    }
            }
            .overlay { Capsule().stroke(.white.opacity(configuration.isPressed ? 0.48 : 0.84), lineWidth: 1) }
            .shadow(color: AppPalette.accent.opacity(0.16), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

enum AppPalette {
    static let ink = Color(red: 0.12, green: 0.14, blue: 0.16)
    static let muted = Color(red: 0.48, green: 0.51, blue: 0.55)
    static let accent = Color(red: 0.00, green: 0.78, blue: 0.49)
    static let aurora = Color(red: 0.17, green: 0.80, blue: 0.64)
    static let couponBlue = Color(red: 0.07, green: 0.73, blue: 0.56)
    static let blueChip = Color(red: 0.89, green: 0.98, blue: 0.94)
    static let topCanvas = Color(red: 0.98, green: 0.99, blue: 0.99)
    static let canvas = Color(red: 0.95, green: 0.97, blue: 0.98)
    static let border = Color(red: 0.89, green: 0.91, blue: 0.93)
    static let warning = Color(red: 0.95, green: 0.19, blue: 0.25)
}
