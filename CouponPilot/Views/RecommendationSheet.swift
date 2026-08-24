import SwiftUI

struct RecommendationSheet: View {
    let recommendation: Recommendation
    var onOpenCoupon: (() -> Void)?

    private var accent: Color { AppPalette.accent }

    var body: some View {
        ZStack {
            RecommendationLiquidBackground(accent: accent)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 15) {
                    hero
                    bestOption
                    if let onOpenCoupon {
                        Button(action: onOpenCoupon) {
                            Label("추천 쿠폰 열기", systemImage: "ticket.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppPalette.accent)
                        .accessibilityHint("쿠폰 이미지와 사용 조건을 확인합니다")
                    }
                    aiExplanation
                    personalizationSection
                    sourceSection
                    alternatives
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
    }

    private var hero: some View {
        RecommendationGlassSurface(tint: accent, cornerRadius: 30) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.34))
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(recommendation.storeName)에서")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                    Text("최대 \(recommendation.recommendedOption.savings.formatted())원\n절약할 수 있어요")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineSpacing(-3)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                Text("계산 결과")
                Text("·")
                Text("공식 조건 반영")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(AppPalette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.48), in: Capsule())
        }
    }

    private var bestOption: some View {
        RecommendationGlassSurface(tint: accent) {
            Label("가장 좋은 조합", systemImage: "seal.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.accent)

            Text(recommendation.recommendedOption.title)
                .font(.title3.weight(.bold))

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(recommendation.recommendedOption.finalPrice.formatted())원")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("정가 \((recommendation.recommendedOption.originalPrice ?? recommendation.originalPrice).formatted())원")
                    .font(.caption)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("−\(recommendation.recommendedOption.savings.formatted())원")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            }

            FlowLayout(spacing: 7) {
                ForEach(recommendation.recommendedOption.badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.56), in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.75), lineWidth: 1) }
                }
            }
        }
    }

    private var aiExplanation: some View {
        RecommendationGlassSurface(tint: accent) {
            Label("생성형 AI가 작성한 추천 설명", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(AppPalette.ink)
            Text(recommendation.explanation)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            Label("금액·절약액·순위는 규칙 기반 Calculator 결과이며 AI가 변경할 수 없어요.", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(AppPalette.accent)
                .fixedSize(horizontal: false, vertical: true)

            Label("쿠폰콕은 결제를 실행하거나 승인하지 않아요. 실제 적용 여부와 결제 금액은 매장·카드사에서 최종 확인해 주세요.", systemImage: "creditcard.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    @ViewBuilder
    private var personalizationSection: some View {
        if let insight = recommendation.personalizationInsight, !insight.isEmpty {
            RecommendationGlassSurface(tint: accent) {
                Label("내 사용 패턴 참고", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                    .foregroundStyle(AppPalette.ink)
                Text(insight)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                Label("개인화 동의 시 최근 쿠폰 사용 이력의 집계만 사용하며, 가격·순위는 바꾸지 않아요.", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(AppPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if !recommendation.benefitSources.isEmpty {
            RecommendationGlassSurface(tint: accent) {
                Label("공식 혜택 근거", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(AppPalette.accent)
                ForEach(recommendation.benefitSources) { source in
                    Link(destination: URL(string: source.sourceURL)!) {
                        HStack(spacing: 11) {
                            Image(systemName: "doc.text.fill")
                                .font(.title3)
                                .foregroundStyle(AppPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.provider).font(.subheadline.weight(.bold))
                                Text(source.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let checkedAt = source.checkedAt {
                                    Text("공식 확인 \(checkedAt)\(source.version.map { " · v\($0)" } ?? "")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                        .padding(13)
                        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.66), lineWidth: 1) }
                    }
                }
            }
        } else {
            RecommendationGlassSurface(tint: accent) {
                Label("공식 혜택 근거 없음", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("현재 매장에 적용할 공식 통신사 혜택 문서를 찾지 못했어요. 통신사 앱에서 최종 적용 여부를 확인해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var alternatives: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("다른 방법")
                .font(.headline)
                .padding(.leading, 4)
            ForEach(recommendation.alternatives) { option in
                RecommendationGlassSurface(tint: accent, cornerRadius: 20) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title).font(.subheadline.weight(.semibold))
                            Text("\(option.savings.formatted())원 절약")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(option.finalPrice.formatted())원")
                            .font(.subheadline.weight(.bold))
                    }
                }
            }
        }
    }
}

private struct RecommendationLiquidBackground: View {
    let accent: Color

    var body: some View {
        LinearGradient(colors: [AppPalette.topCanvas, AppPalette.canvas], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

private struct RecommendationGlassSurface<Content: View>: View {
    let tint: Color
    var cornerRadius: CGFloat = 24
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppPalette.border, lineWidth: 1)
            }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(for: subviews, in: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1) * spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, in width: CGFloat) -> [(indices: [Int], height: CGFloat)] {
        var result: [(indices: [Int], height: CGFloat)] = []
        var row: [Int] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let requiredWidth = row.isEmpty ? size.width : rowWidth + spacing + size.width
            if !row.isEmpty && requiredWidth > width {
                result.append((row, rowHeight))
                row = []
                rowWidth = 0
                rowHeight = 0
            }
            row.append(index)
            rowWidth = row.count == 1 ? size.width : rowWidth + spacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
        if !row.isEmpty { result.append((row, rowHeight)) }
        return result
    }
}
