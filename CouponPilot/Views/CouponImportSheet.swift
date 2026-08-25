import PhotosUI
import SwiftUI
import UIKit

struct CouponImportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var rawText = ""
    @State private var draft = CouponDraft()
    @State private var isRecognizing = false
    @State private var usedAINormalization = false
    @State private var barcodeCandidates: [CouponBarcodeCandidate] = []
    @State private var selectedBarcode: CouponBarcodeCandidate?
    @State private var saveRedeemableBarcode = false
    @State private var officialPriceEvidence: OfficialProductPriceMatch?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    imagePicker

                    if isRecognizing {
                        HStack(spacing: 12) {
                            ProgressView().tint(AppPalette.accent)
                            Text("기기에서 쿠폰을 읽고 AI가 초안을 정리하는 중이에요")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(AppPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.warning)
                    }

                    if previewImage != nil, !isRecognizing {
                        couponForm
                        barcodeConfirmation
                        rawTextPreview
                    }
                }
                .padding(20)
            }
            .navigationTitle("쿠폰 이미지 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        if let previewImage, draft.expiresAt >= Calendar.current.startOfDay(for: .now) {
                            appState.saveImportedCoupon(
                                draft: draft,
                                image: previewImage,
                                barcode: saveRedeemableBarcode ? selectedBarcode : nil
                            )
                            dismiss()
                        }
                    }
                    .fontWeight(.bold)
                    .disabled(previewImage == nil || isRecognizing || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.expiresAt < Calendar.current.startOfDay(for: .now))
                }
            }
        }
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await recognize(item) }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("사진에서 쿠폰을 읽어요")
                .font(.title2.weight(.bold))
            Text("원본 이미지는 서버로 전송되지 않고 이 기기에만 보관됩니다. 바코드·연락처를 기기에서 제거한 OCR 텍스트만 AI 정리를 위해 인증된 서버로 전송하며, 서버에는 원문을 저장하지 않습니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var imagePicker: some View {
        let displayedImage = previewImage
        return VStack(spacing: 10) {
            PhotosPicker(selection: $selectedItem, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppPalette.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [7])) }
                    if let displayedImage {
                        Image(uiImage: displayedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 208)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                Label("사진 변경", systemImage: "photo.on.rectangle")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(12)
                            }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(AppPalette.accent)
                            Text("쿠폰 이미지 선택")
                                .font(.headline)
                            Text("스크린샷이나 사진을 골라주세요")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 208)
            }
            .buttonStyle(.plain)

        }
    }

    private var couponForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("인식 결과 확인").font(.headline)
            Picker("프랜차이즈", selection: $draft.brand) {
                Text("선택해 주세요").tag("")
                ForEach(SupportedFranchise.allCases) { franchise in
                    Text(franchise.displayName).tag(franchise.displayName)
                }
            }
            Text("위치 추천은 지원 프랜차이즈 14곳의 쿠폰만 가능해요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if usedAINormalization {
                Label(draft.requiresConfirmation ? "AI 초안 · 할인 조건을 확인해 주세요" : "AI가 OCR 초안을 정리했어요", systemImage: draft.requiresConfirmation ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(draft.requiresConfirmation ? AppPalette.warning : AppPalette.accent)
            }
            TextField("쿠폰 이름", text: $draft.title, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)

            Picker("할인 방식", selection: $draft.discountType) {
                Text("금액 할인").tag(Coupon.DiscountType.fixedAmount)
                Text("퍼센트 할인").tag(Coupon.DiscountType.percentage)
            }
            .pickerStyle(.segmented)

            HStack {
                Text(draft.discountType == .fixedAmount ? "할인 금액" : "할인율")
                Spacer()
                TextField("0", value: $draft.discountValue, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 86)
                Text(draft.discountType == .fixedAmount ? "원" : "%")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("상품 기준가")
                Spacer()
                TextField("미확인", value: $draft.referencePrice, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 86)
                Text("원").foregroundStyle(.secondary)
            }
            if !AppState.isSubmissionSimulation {
                Text("사진에 상품가·정상가가 명시된 경우에만 자동 입력합니다. 없으면 비워 두고 확인해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let officialPriceEvidence {
                Label("공식 가격 문서 확인 · \(officialPriceEvidence.checkedAt)", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.accent)
                    .accessibilityLabel("공식 가격 문서 \(officialPriceEvidence.sourceTitle), \(officialPriceEvidence.checkedAt) 확인")
            }

            DatePicker(
                "유효기간",
                selection: $draft.expiresAt,
                in: Calendar.current.startOfDay(for: .now)...,
                displayedComponents: .date
            )
            if draft.discountType == .percentage {
                HStack {
                    Text("최대 할인액")
                    Spacer()
                    TextField("없음", value: $draft.maximumDiscount, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 86)
                    Text("원").foregroundStyle(.secondary)
                }
                Text("쿠폰에 최대 할인액이 적혀 있다면 입력해 주세요. 없으면 비워둘 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("사용 조건 (쉼표로 구분)", text: conditionsText)
                .textFieldStyle(.roundedBorder)
            Toggle("카드 혜택과 중복 가능", isOn: $draft.combinableWithCard)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var conditionsText: Binding<String> {
        Binding(
            get: { draft.conditions.joined(separator: ", ") },
            set: { draft.conditions = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        )
    }

    private var rawTextPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OCR 인식 원문")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("저장되지 않음")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            }
            Text(rawText.isEmpty ? "읽을 수 있는 문구가 없습니다." : rawText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(5)
        }
        .padding(15)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var barcodeConfirmation: some View {
        if !barcodeCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("교환용 바코드를 찾았어요", systemImage: "barcode.viewfinder")
                    .font(.headline)
                Text("실제 교환 코드는 이 iPhone의 암호화된 보관소에만 저장됩니다. Firebase, Gemini, 추천 서버에는 전송하지 않아요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(barcodeCandidates) { candidate in
                    Button {
                        selectedBarcode = candidate
                    } label: {
                        HStack {
                            Image(systemName: selectedBarcode == candidate ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedBarcode == candidate ? AppPalette.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.format.title).font(.subheadline.weight(.semibold))
                                Text(candidate.maskedValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                Toggle("선택한 코드를 교환용으로 저장", isOn: $saveRedeemableBarcode)
                    .tint(AppPalette.accent)
                    .disabled(selectedBarcode == nil)
                Text("발급처의 사용 조건을 확인한 뒤 저장하세요. 쿠폰을 삭제하면 이 코드도 함께 지워집니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    @MainActor
    private func recognize(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw OCRServiceError.invalidImage
            }
            await recognize(image)
        } catch {
            errorMessage = "이미지를 읽지 못했어요. 더 선명한 쿠폰 이미지를 선택해 주세요."
        }
    }

    @MainActor
    private func recognize(_ image: UIImage) async {
        isRecognizing = true
        errorMessage = nil
        defer { isRecognizing = false }

        do {
            previewImage = image
            let ocr = CouponOCRService()
            // Run Vision requests in a defined order. It is only a few milliseconds slower for
            // one imported coupon and avoids competing OCR/barcode requests on Simulator.
            rawText = try await ocr.recognizeRawText(in: image)
            barcodeCandidates = (try? await ocr.detectRedeemableCouponBarcodes(in: image)) ?? []
            selectedBarcode = barcodeCandidates.first
            saveRedeemableBarcode = false
            draft = CouponOCRParser.makeDraft(from: rawText)
            usedAINormalization = false
            officialPriceEvidence = nil
            if AppState.isSubmissionSimulation {
                draft.referencePrice = SubmissionCapturePriceCatalog.referencePrice(
                    brand: draft.brand,
                    productName: draft.title
                )
            }
            let redactedRemoteText = CouponOCRParser.redactedForRemoteNormalization(rawText)
            if !AppState.isSubmissionSimulation, await appState.ensureFirebaseAuthentication() {
                let service = AgentAPIService()
                if !redactedRemoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let normalization = try? await service.normalizeCoupon(rawText: redactedRemoteText) {
                    draft.applyLLMNormalization(normalization)
                    usedAINormalization = true
                }
                if !draft.brand.isEmpty,
                   !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let price = try? await service.fetchOfficialProductPrice(brand: draft.brand, productName: draft.title) {
                    draft.referencePrice = price.priceWon
                    officialPriceEvidence = price
                }
            }
        } catch {
            errorMessage = "이미지를 읽지 못했어요. 더 선명한 쿠폰 이미지를 선택해 주세요."
        }
    }
}
