import Foundation
import UIKit
@preconcurrency import Vision

struct CouponOCRService {
    /// UIImage는 메모리에서만 처리하고 서버로 업로드하지 않습니다.
    func recognizeRawText(in image: UIImage) async throws -> String {
        let boxes = try await recognizeTextBoxes(in: image)
        return boxes.map(\.text).joined(separator: "\n")
    }

    private func recognizeTextBoxes(in image: UIImage) async throws -> [RecognizedTextBox] {
        guard let cgImage = image.cgImage else { throw OCRServiceError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = VisionContinuationGate(continuation)
            let request = VNRecognizeTextRequest { request, error in
                if let error { gate.resume(.failure(error)); return }
                let boxes = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { observation -> RecognizedTextBox? in
                        guard let text = observation.topCandidates(1).first?.string,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return RecognizedTextBox(text: text, normalizedBoundingBox: observation.boundingBox)
                    } ?? []
                gate.resume(.success(boxes))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR", "en-US"]

            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) }
                catch { gate.resume(.failure(error)) }
            }
        }
    }

    /// Reads only enough text to match a user-confirmed card product. The image, OCR text,
    /// PAN, expiry date and CVC never leave the device and are not returned to the caller.
    func recognizeCardProduct(in image: UIImage) async throws -> CardRecognitionResult {
        let rawText = try await recognizeRawText(in: image)
        let normalized = rawText
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ko_KR"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
            .lowercased()
        let hasLongNumber = rawText.range(of: #"(?:\d[ -]?){12,19}"#, options: .regularExpression) != nil

        let matchedCard: PaymentCard?
        if normalized.contains("mrlife") || normalized.contains("미스터라이프") {
            matchedCard = PaymentCard.catalog.first { $0.productId == "shinhancard-mr-life" }
        } else if normalized.contains("톡톡pay") || normalized.contains("톡톡페이") {
            matchedCard = PaymentCard.catalog.first { $0.productId == "kbcard-talktalk-pay" }
        } else if normalized.contains("현대카드m") || normalized.contains("hyundaicardm") {
            matchedCard = PaymentCard.catalog.first { $0.productId == "hyundaicard-m" }
        } else {
            matchedCard = nil
        }
        return CardRecognitionResult(card: matchedCard, sensitiveNumberDetectedAndIgnored: hasLongNumber)
    }

    /// Finds only formats that CouponCock can faithfully re-render with Core Image. The source
    /// photo and payload remain on the iPhone; this result is never used in remote OCR/AI calls.
    func detectRedeemableCouponBarcodes(in image: UIImage) async throws -> [CouponBarcodeCandidate] {
        guard let cgImage = image.cgImage else { throw OCRServiceError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = VisionContinuationGate(continuation)
            let request = VNDetectBarcodesRequest { request, error in
                if let error { gate.resume(.failure(error)); return }
                let candidates = ((request.results as? [VNBarcodeObservation]) ?? []).compactMap { observation -> CouponBarcodeCandidate? in
                    guard let value = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty,
                          value.utf8.count <= 512,
                          let format = couponBarcodeFormat(for: observation.symbology) else { return nil }
                    return CouponBarcodeCandidate(value: value, format: format)
                }
                let unique = Array(Dictionary(grouping: candidates, by: \.id).values.compactMap(\.first))
                gate.resume(.success(unique))
            }
            request.symbologies = [.code128, .qr, .dataMatrix, .pdf417, .aztec]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) }
                catch { gate.resume(.failure(error)) }
            }
        }
    }

    /// Prepares a one-time card-identification payload. The original front and back photos never
    /// leave the device and are never written to disk. The back remains OCR-only. The front may
    /// leave the device only as a visual signature after all detected text and conservative PAN
    /// zones are covered, then Vision confirms no readable text remains (fail closed).
    func prepareSafeCardRecognitionPayload(front: UIImage, back: UIImage) async throws -> SafeCardRecognitionPayload {
        async let frontBoxes = recognizeTextBoxes(in: front)
        async let backText = recognizeRawText(in: back)
        let (frontTextBoxes, backRawText) = try await (frontBoxes, backText)
        let frontRawText = frontTextBoxes.map(\.text).joined(separator: "\n")

        let frontSafeText = CardPrivacyRedactor.redact(frontRawText)
        let backSafeText = CardPrivacyRedactor.redact(backRawText)
        guard !(frontSafeText.text + backSafeText.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw OCRServiceError.noNonSensitiveCardIdentity
        }
        let visualSignature = try CardVisualSignature.redactedFront(from: front, textBoxes: frontTextBoxes)
        let remainingText = try await recognizeTextBoxes(in: visualSignature)
        guard remainingText.isEmpty else { throw OCRServiceError.residualTextDetected }
        guard let imageData = CardVisualSignature.compressedJPEG(from: visualSignature) else { throw OCRServiceError.safeImageTooLarge }

        return SafeCardRecognitionPayload(
            frontText: frontSafeText.text,
            backText: backSafeText.text,
            frontVisualSignatureBase64: imageData.base64EncodedString(),
            sensitiveValuesMasked: frontSafeText.maskedSensitiveValues || backSafeText.maskedSensitiveValues
        )
    }
}

/// Vision can invoke a request completion and still surface an error from `perform(_:)` while
/// the request handler unwinds. CheckedContinuation traps on a second resume, so every Vision
/// bridge uses this lock-protected one-shot gate.
private final class VisionContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private func couponBarcodeFormat(for symbology: VNBarcodeSymbology) -> CouponBarcodeCandidate.Format? {
    switch symbology {
    case .code128: .code128
    case .qr: .qr
    case .dataMatrix: .dataMatrix
    case .pdf417: .pdf417
    case .aztec: .aztec
    default: nil
    }
}

struct CardRecognitionResult: Equatable {
    let card: PaymentCard?
    let sensitiveNumberDetectedAndIgnored: Bool
}

private struct RecognizedTextBox {
    let text: String
    let normalizedBoundingBox: CGRect
}

/// This payload is memory-only. Its visual field contains a re-rendered, text-free front image;
/// the original `UIImage`, original OCR text and back image never appear in this model.
struct SafeCardRecognitionPayload: Equatable {
    let frontText: String
    let backText: String
    let frontVisualSignatureBase64: String
    let sensitiveValuesMasked: Bool
}

private enum CardVisualSignature {
    /// 120 KB leaves headroom under the API's 256 KB body limit and avoids retaining a detailed image.
    private static let maximumBytes = 120_000

    static func redactedFront(from image: UIImage, textBoxes: [RecognizedTextBox]) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw OCRServiceError.invalidImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { throw OCRServiceError.invalidImage }
        let normalized = UIImage(cgImage: cgImage)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            normalized.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            context.cgContext.setFillColor(UIColor.black.cgColor)
            // Mask every text observation, not only values that happen to match a PAN regex.
            for box in textBoxes {
                let rect = CGRect(
                    x: box.normalizedBoundingBox.minX * width,
                    y: (1 - box.normalizedBoundingBox.maxY) * height,
                    width: box.normalizedBoundingBox.width * width,
                    height: box.normalizedBoundingBox.height * height
                ).insetBy(dx: -18, dy: -14).intersection(CGRect(x: 0, y: 0, width: width, height: height))
                context.cgContext.fill(rect)
            }
            // OCR can miss embossed or vertical digits. Discard the lower half, where PAN, name,
            // expiry and network security marks are commonly placed, even when no text was read.
            context.cgContext.fill(CGRect(x: 0, y: height * 0.50, width: width, height: height * 0.50))
        }
    }

    static func compressedJPEG(from image: UIImage) -> Data? {
        let candidates: [(CGFloat, CGFloat)] = [(720, 0.45), (560, 0.40), (420, 0.35)]
        for (targetWidth, quality) in candidates {
            let scale = min(1, targetWidth / image.size.width)
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= maximumBytes { return data }
        }
        return nil
    }
}

private enum CardPrivacyRedactor {
    private static let sensitivePatterns: [String] = [
        #"(?:\d[\s-]?){3,}"#, // Includes every PAN group, even when Vision splits the full number.
        #"\b(?:0?[1-9]|1[0-2])\s*[/.-]\s*(?:\d{2}|\d{4})\b"#,
        #"(?i)\b(?:cvc|cvv|security\s*code|유효기간)\b\s*[:#-]?\s*\d{0,4}"#,
        #"(?i)\b(?:barcode|바코드)\b\s*[:#-]?\s*[A-Z0-9 -]{3,}"#
    ]

    static func redact(_ rawText: String) -> (text: String, maskedSensitiveValues: Bool) {
        var text = rawText
        var masked = false
        for pattern in sensitivePatterns {
            let updated = text.replacingOccurrences(of: pattern, with: "[민감정보 제거]", options: .regularExpression)
            if updated != text { masked = true }
            text = updated
        }
        // Vision occasionally includes e-mail or a phone number in a card photo. They are not
        // needed for issuer/product matching and therefore never leave the device either.
        text = CouponOCRParser.redactedForRemoteNormalization(text)
        return (text: text.prefix(2_500).description, maskedSensitiveValues: masked)
    }

}

enum OCRServiceError: Error {
    case invalidImage
    case noNonSensitiveCardIdentity
    case residualTextDetected
    case safeImageTooLarge
}

enum CouponOCRParser {
    /// 서버 정규화에는 쿠폰 조건 판단에 불필요한 바코드·연락처를 보내지 않습니다.
    /// 서버도 같은 검사를 반복하지만, 기기에서 먼저 제거해 전송 자체를 최소화합니다.
    static func redactedForRemoteNormalization(_ rawText: String) -> String {
        let patterns: [(String, String)] = [
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[이메일 제거]"),
            (#"(?:\+?82[-\s]?)?0?1[016789](?:[-\s]?\d){7,8}"#, "[전화번호 제거]"),
            (#"\d{6}[-\s]?[1-4]\d{6}"#, "[식별번호 제거]"),
            (#"(?:\d[\s-]?){12,19}"#, "[바코드 번호 제거]")
        ]
        return patterns.reduce(rawText) { partial, item in
            partial.replacingOccurrences(
                of: item.0,
                with: item.1,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    /// LLM 정규화 도구 호출 전에도 앱에서 즉시 보여 줄 수 있는 보수적 초안입니다.
    static func makeDraft(from rawText: String) -> CouponDraft {
        let lines = rawText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var draft = CouponDraft()
        let joined = lines.joined(separator: " ")
        draft.brand = SupportedFranchise.detected(in: joined)?.displayName ?? ""
        draft.title = bestProductTitle(from: lines, brand: draft.brand)

        if let amount = firstNumber(matching: #"(\d{1,3}(?:,\d{3})*)\s*원\s*할인"#, in: joined) {
            draft.discountType = .fixedAmount
            draft.discountValue = amount
        } else if let percentage = firstNumber(matching: #"(\d{1,2})\s*%"#, in: joined) {
            draft.discountType = .percentage
            draft.discountValue = percentage
        }

        if let expiry = expiryDate(in: joined) { draft.expiresAt = expiry }
        // A product price is usable only when the image explicitly labels it as such. A barcode
        // value, gift value, or discount amount must never become a Calculator reference price.
        draft.referencePrice = explicitProductPrice(in: joined)
        return draft
    }

    private static func bestProductTitle(from lines: [String], brand: String) -> String {
        let excludedTerms = [
            "유효기간", "주문번호", "교환처", "바코드", "선물하기", "카카오톡", "사용처",
            "교환권", "쿠폰번호", "결제", "고객센터", "주의사항", "상품가격", "정상가", "판매가"
        ]
        let productHints = [
            "아메리카노", "라떼", "프라푸치노", "콜드브루", "티", "tea", "coffee", "카스텔라",
            "케이크", "베이커리", "음료", "샌드위치", "세트", "잔", "tall", "grande", "venti"
        ]

        let candidates = lines.compactMap { rawLine -> (title: String, score: Int)? in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 3 else { return nil }
            guard !excludedTerms.contains(where: { line.localizedCaseInsensitiveContains($0) }) else { return nil }
            guard !line.localizedCaseInsensitiveContains("만료") else { return nil }

            if !brand.isEmpty {
                line = line.replacingOccurrences(of: brand, with: "", options: [.caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            line = line.replacingOccurrences(of: #"^(?:상품명|상품)\\s*[:：]?\\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 3,
                  line.rangeOfCharacter(from: .letters) != nil else { return nil }

            let hintScore = productHints.reduce(0) { partial, hint in
                partial + (line.localizedCaseInsensitiveContains(hint) ? 30 : 0)
            }
            // Product names are normally descriptive but short. Penalize long boilerplate.
            let lengthScore = max(0, 36 - abs(line.count - 22))
            return (line, hintScore + lengthScore)
        }
        return candidates.max(by: { $0.score < $1.score })?.title ?? ""
    }

    private static func explicitProductPrice(in text: String) -> Int? {
        firstNumber(
            matching: #"(?:상품가격|상품가|정상가|판매가)\\s*[:：]?\\s*(\\d{1,3}(?:,\\d{3})*)\\s*원"#,
            in: text
        )
    }

    private static func firstNumber(matching pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range].replacingOccurrences(of: ",", with: ""))
    }

    private static func expiryDate(in text: String) -> Date? {
        let pattern = #"(20\d{2})\s*[년.\-/]\s*(\d{1,2})\s*[월.\-/]\s*(\d{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let values = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        guard values.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
}

/// Capture-only product composition prices. This fixture is never used in a normal app,
/// synchronized wallet, recommendation request, or Cloud Run calculation.
enum SubmissionCapturePriceCatalog {
    static func referencePrice(brand: String, productName: String) -> Int? {
        guard SupportedFranchise.detected(in: brand) == .starbucks else { return nil }
        let normalized = productName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let twoTallAmericanos = [
            "아이스카페아메리카노t2잔",
            "아이스카페아메리카노tall2잔",
            "아이스카페아메리카노2잔"
        ]
        return twoTallAmericanos.contains(normalized) ? 9_400 : nil
    }
}
