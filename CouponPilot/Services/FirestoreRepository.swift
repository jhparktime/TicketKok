@preconcurrency import FirebaseFirestore

/// Coupon images and OCR raw text are intentionally excluded: only confirmed coupon fields are synced.
@MainActor
final class FirestoreRepository {
    static let shared = FirestoreRepository()
    private let database = Firestore.firestore()

    func loadUserData(uid: String) async throws -> (profile: UserProfile?, coupons: [Coupon], usedCoupons: [UsedCoupon]) {
        async let profileSnapshot = database.collection("users").document(uid).getDocument()
        async let couponSnapshot = database.collection("users").document(uid).collection("coupons").getDocuments()
        async let usedCouponSnapshot = database.collection("users").document(uid).collection("usedCoupons").getDocuments()
        let (profileDocument, couponDocuments, usedCouponDocuments) = try await (profileSnapshot, couponSnapshot, usedCouponSnapshot)
        let profile = profileDocument.exists ? profile(from: profileDocument.data() ?? [:], fallbackID: uid) : nil
        let coupons = couponDocuments.documents.compactMap { coupon(from: $0.data(), id: $0.documentID) }
        let usedCoupons = usedCouponDocuments.documents.compactMap { usedCoupon(from: $0.data(), id: $0.documentID) }
        return (profile, coupons, usedCoupons)
    }

    func save(profile: UserProfile, uid: String) async throws {
        try await database.collection("users").document(uid).setData([
            "carrier": profile.carrier,
            "membershipGrade": profile.membershipGrade,
            "monthlyBenefitStatus": profile.monthlyBenefitStatus.rawValue,
            "cards": profile.cards.map { card in
                [
                    "issuer": card.issuer,
                    "productId": card.productId,
                    "productName": card.productName,
                    "previousMonthSpendQualified": card.previousMonthSpendQualified,
                    "monthlyBenefitRemainingAmount": card.monthlyBenefitRemainingAmount
                ]
            },
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func clearPersonalization(uid: String) async throws {
        try await database.collection("users").document(uid).setData([
            "carrier": FieldValue.delete(),
            "membershipGrade": FieldValue.delete(),
            "monthlyBenefitStatus": FieldValue.delete(),
            "cards": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func save(consent: PrivacyConsent, uid: String) async throws {
        var data: [String: Any] = [
            "policyVersion": consent.policyVersion,
            "requiredProcessingAccepted": consent.requiredProcessingAccepted,
            "personalizationAccepted": consent.personalizationAccepted,
            "locationPersonalizationAccepted": consent.locationPersonalizationAccepted,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let acceptedAt = consent.acceptedAt { data["acceptedAt"] = Timestamp(date: acceptedAt) }
        try await database.collection("users").document(uid).collection("consents")
            .document(consent.policyVersion).setData(data, merge: true)
    }

    func save(coupon: Coupon, uid: String) async throws {
        let user = database.collection("users").document(uid)
        var data = couponData(coupon)
        data["updatedAt"] = FieldValue.serverTimestamp()
        let batch = database.batch()
        batch.setData(data, forDocument: user.collection("coupons").document(coupon.id), merge: true)
        batch.deleteDocument(user.collection("usedCoupons").document(coupon.id))
        try await batch.commit()
    }

    func delete(couponID: String, uid: String) async throws {
        try await database.collection("users").document(uid).collection("coupons").document(couponID).delete()
    }

    func moveToUsedHistory(coupon: Coupon, uid: String) async throws {
        try await save(usedCoupon: UsedCoupon(coupon: coupon), uid: uid)
    }

    func save(usedCoupon: UsedCoupon, uid: String) async throws {
        let user = database.collection("users").document(uid)
        let batch = database.batch()
        var data: [String: Any] = [
            "brand": usedCoupon.brand,
            "productName": usedCoupon.productName,
            "expiresAt": Timestamp(date: usedCoupon.expiresAt),
            "usedAt": Timestamp(date: usedCoupon.usedAt),
            "source": usedCoupon.source
        ]
        if let storeName = usedCoupon.storeName { data["storeName"] = storeName }
        if let paidAmount = usedCoupon.paidAmount { data["paidAmount"] = paidAmount }
        if let savings = usedCoupon.savings { data["savings"] = savings }
        if let originalCoupon = usedCoupon.originalCoupon {
            data["originalCoupon"] = couponData(originalCoupon)
        }
        batch.setData(data, forDocument: user.collection("usedCoupons").document(usedCoupon.id), merge: true)
        batch.deleteDocument(user.collection("coupons").document(usedCoupon.id))
        try await batch.commit()
    }

    /// Deletes only the authenticated user's application records. Coupon images live on the
    /// device and are removed by AppState separately; no raw OCR text is stored in Firestore.
    func deleteAllUserData(uid: String) async throws {
        let user = database.collection("users").document(uid)
        async let couponSnapshot = user.collection("coupons").getDocuments()
        async let usedCouponSnapshot = user.collection("usedCoupons").getDocuments()
        async let consentSnapshot = user.collection("consents").getDocuments()
        let (coupons, usedCoupons, consents) = try await (couponSnapshot, usedCouponSnapshot, consentSnapshot)
        let batch = database.batch()
        coupons.documents.forEach { batch.deleteDocument($0.reference) }
        usedCoupons.documents.forEach { batch.deleteDocument($0.reference) }
        consents.documents.forEach { batch.deleteDocument($0.reference) }
        batch.deleteDocument(user)
        try await batch.commit()
    }

    private func profile(from data: [String: Any], fallbackID: String) -> UserProfile? {
        guard let carrier = data["carrier"] as? String else { return nil }
        let grade = data["membershipGrade"] as? String ?? "확인 필요"
        let status = UserProfile.MonthlyBenefitStatus(rawValue: data["monthlyBenefitStatus"] as? String ?? "") ?? .unknown
        let cards = (data["cards"] as? [[String: Any]] ?? []).compactMap { card -> PaymentCard? in
            guard let issuer = card["issuer"] as? String,
                  let productId = card["productId"] as? String,
                  let productName = card["productName"] as? String,
                  let previousMonthSpendQualified = card["previousMonthSpendQualified"] as? Bool,
                  let monthlyBenefitRemainingAmount = card["monthlyBenefitRemainingAmount"] as? Int else { return nil }
            return PaymentCard(
                issuer: issuer,
                productId: productId,
                productName: productName,
                previousMonthSpendQualified: previousMonthSpendQualified,
                monthlyBenefitRemainingAmount: monthlyBenefitRemainingAmount
            )
        }
        return UserProfile(id: fallbackID, carrier: carrier, membershipGrade: grade, monthlyBenefitStatus: status, cards: cards)
    }

    private func coupon(from data: [String: Any], id: String) -> Coupon? {
        guard let brand = data["brand"] as? String,
              let title = data["title"] as? String,
              let rawType = data["discountType"] as? String,
              let discountType = Coupon.DiscountType(rawValue: rawType),
              let discountValue = data["discountValue"] as? Int,
              let minimumOrderAmount = data["minimumOrderAmount"] as? Int,
              let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(),
              let combinableWithCard = data["combinableWithCard"] as? Bool else { return nil }
        return Coupon(id: id, brand: brand, title: title, discountType: discountType, discountValue: discountValue,
                      minimumOrderAmount: minimumOrderAmount, maximumDiscount: data["maximumDiscount"] as? Int,
                      expiresAt: expiresAt, combinableWithCard: combinableWithCard,
                      referencePrice: data["referencePrice"] as? Int,
                      conditions: data["conditions"] as? [String] ?? [], localImageFilename: nil)
    }

    private func usedCoupon(from data: [String: Any], id: String) -> UsedCoupon? {
        guard let brand = data["brand"] as? String,
              let productName = data["productName"] as? String,
              let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
        let usedAt = (data["usedAt"] as? Timestamp)?.dateValue() ?? .now
        let originalCoupon = (data["originalCoupon"] as? [String: Any]).flatMap { coupon(from: $0, id: id) }
        return UsedCoupon(
            id: id,
            brand: brand,
            productName: productName,
            expiresAt: expiresAt,
            orderNumber: "앱에서 사용 처리",
            barcodeLast4: "-",
            usedAt: usedAt,
            source: data["source"] as? String ?? "CouponPilot",
            storeName: data["storeName"] as? String,
            paidAmount: data["paidAmount"] as? Int,
            savings: data["savings"] as? Int,
            originalCoupon: originalCoupon
        )
    }

    private func couponData(_ coupon: Coupon) -> [String: Any] {
        var data: [String: Any] = [
            "brand": coupon.brand,
            "title": coupon.title,
            "discountType": coupon.discountType.rawValue,
            "discountValue": coupon.discountValue,
            "minimumOrderAmount": coupon.minimumOrderAmount,
            "expiresAt": Timestamp(date: coupon.expiresAt),
            "combinableWithCard": coupon.combinableWithCard,
            "conditions": coupon.conditions
        ]
        if let referencePrice = coupon.referencePrice { data["referencePrice"] = referencePrice }
        if let maximumDiscount = coupon.maximumDiscount { data["maximumDiscount"] = maximumDiscount }
        return data
    }
}
