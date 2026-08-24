import SwiftUI
import SwiftData

/// One insight card's content (V2-14). Every insight is worded as an estimate,
/// carries its own accessible summary, and never shames.
struct InsightCardData: Identifiable {
    enum Tone {
        case neutral
        case positive
        case attention
    }

    let id: String
    let title: String
    let headline: String
    let detail: String
    let tone: Tone
    let symbol: String
}

/// The insight row hosted at the top of the Progress tab (§8.5).
/// Cards appear only when the underlying data supports them — an insight is
/// never shown with a placeholder number.
struct InsightsRow: View {
    let insights: [InsightCardData]

    var body: some View {
        if insights.isEmpty {
            DashboardCard(title: "Insights", systemImage: "sparkles") {
                Text("Insights appear as you record paydays and balances. Nothing is estimated from figures you haven't entered.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(insights) { insight in
                        InsightCardView(insight: insight)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("progress.insightsRow")
        }
    }
}

struct InsightCardView: View {
    let insight: InsightCardData

    private var toneColor: Color {
        switch insight.tone {
        case .neutral: return .secondary
        case .positive: return .mint
        case .attention: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(insight.title, systemImage: insight.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(toneColor)
            Text(insight.headline)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(insight.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.title). \(insight.headline) \(insight.detail)")
    }
}

/// Builds the five V2-14 insight cards from stored data.
@MainActor
enum InsightsBuilder {

    static func build(context: ModelContext, environment: AppEnvironment) -> [InsightCardData] {
        var cards: [InsightCardData] = []
        let plans = (try? context.fetch(FetchDescriptor<PlanVersion>())) ?? []
        let baseline = (try? PlanRepository.legacyBaseline(context: context)) ?? nil
        guard let plan = plans.first(where: \.isActive) ?? baseline else { return cards }

        let balanceService = environment.balanceService(context: context)
        let balances = (try? balanceService.debtBalances()) ?? []
        let forecast = try? environment.reforecastService(context: context).latestForecast()

        // 1. Interest saved vs. minimums only (modern engine only — the engine
        //    withholds the comparison when inputs can't support it).
        if plan.calculationVersion >= PlanContract.minimumModernCalculationVersion {
            let service = GeneratedPlanService(context: context, dateProvider: environment.dateProvider)
            if let result = (try? service.baselineResult(for: plan)) ?? nil {
                if let saved = result.minimumOnlyComparison?.interestSaved, saved > 0 {
                    cards.append(InsightCardData(
                        id: "interest-saved",
                        title: "Interest saved",
                        headline: "About \(MoneyFormat.string(saved)) less interest",
                        detail: "Estimated against paying only the minimums on every debt. Actual issuer interest will differ.",
                        tone: .positive,
                        symbol: "arrow.down.right.circle"
                    ))
                } else if result.minimumOnlyComparison == nil {
                    cards.append(InsightCardData(
                        id: "interest-saved-unavailable",
                        title: "Interest saved",
                        headline: "Not enough entered to compare",
                        detail: "Add the contractual payment for every non-card debt and this comparison appears.",
                        tone: .neutral,
                        symbol: "arrow.down.right.circle"
                    ))
                }
            }
        }

        // 2. Payoff delta — reforecast versus this plan's baseline.
        if let projected = forecast?.projectedPayoffDate {
            let delta = DateMath.days(from: plan.baselinePayoffDate, to: projected)
            let headline: String
            let tone: InsightCardData.Tone
            if delta == 0 {
                headline = "Right on the baseline date"
                tone = .neutral
            } else if delta < 0 {
                headline = "About \(abs(delta)) day\(abs(delta) == 1 ? "" : "s") earlier"
                tone = .positive
            } else {
                headline = "About \(delta) day\(delta == 1 ? "" : "s") later"
                tone = .attention
            }
            cards.append(InsightCardData(
                id: "payoff-delta",
                title: "Payoff date",
                headline: headline,
                detail: "Current estimate \(DateMath.mediumString(projected)) versus the plan's \(DateMath.mediumString(plan.baselinePayoffDate)). The plan itself is unchanged.",
                tone: tone,
                symbol: "calendar"
            ))
        }

        // 3. Utilization — only for cards that actually have a limit.
        let utilized = balances.compactMap { item -> (AccountBalanceService.DebtBalance, Decimal)? in
            guard let utilization = item.debt.utilization(currentBalance: item.balance) else { return nil }
            return (item, utilization)
        }
        if let highest = utilized.max(by: { $0.1 < $1.1 }) {
            let level = UtilizationDisplayLevel.level(for: highest.1)
            cards.append(InsightCardData(
                id: "utilization",
                title: "Card utilization",
                headline: "\(highest.0.debt.displayName) at \(UtilizationMath.wholePercentString(highest.1)) of its limit",
                detail: level == .critical
                    ? "Above 90% — worth attention when you can."
                    : (level == .elevated ? "Above 30%. Utilization is display only; it never changes the plan." : "Comfortably under 30%."),
                tone: level == .critical ? .attention : (level == .elevated ? .neutral : .positive),
                symbol: "creditcard"
            ))
        }

        // 4. Obligation crunch — paydays flagged by the R-09 shortfall rule.
        let planID = plan.id
        let items = (try? context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )) ?? []
        let today = DateMath.startOfDay(environment.dateProvider.now)
        let crunch = items
            .filter { $0.shortfallAmount != nil && DateMath.startOfDay($0.date) >= today }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        if let next = crunch.first, let gap = next.shortfallAmount {
            cards.append(InsightCardData(
                id: "obligation-crunch",
                title: "Tight payday ahead",
                headline: "Payday #\(next.sequenceNumber) needs about \(MoneyFormat.string(gap)) more",
                detail: "\(crunch.count) upcoming payday\(crunch.count == 1 ? "" : "s") where obligations and minimums use the whole check. Minimums stay covered in the plan.",
                tone: .attention,
                symbol: "exclamationmark.triangle"
            ))
        }

        // 5. Allowance trend — recorded spending versus the cap.
        if let trend = allowanceTrend(context: context, plan: plan, items: items, today: today) {
            cards.append(trend)
        }

        return cards
    }

    /// Allowance used versus available over the recent pay periods. Neutral
    /// wording: an unspent allowance is not a target the user missed.
    private static func allowanceTrend(
        context: ModelContext,
        plan: PlanVersion,
        items: [PaydayPlanItem],
        today: Date
    ) -> InsightCardData? {
        let pastPaydays = items
            .filter { DateMath.startOfDay($0.date) <= today }
            .sorted { $0.date < $1.date }
            .suffix(3)
        guard pastPaydays.count >= 1, plan.allowanceCap > 0 else { return nil }
        guard let windowStart = pastPaydays.first.map({ DateMath.startOfDay($0.date) }) else { return nil }

        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        let spent = entries
            .filter {
                $0.type == .c1Spending
                    && DateMath.startOfDay($0.effectiveDate) >= windowStart
                    && DateMath.startOfDay($0.effectiveDate) <= today
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let available = plan.allowanceCap * Decimal(pastPaydays.count)
        guard available > 0 else { return nil }
        let unspent = max(.zero, available - spent).rounded2

        return InsightCardData(
            id: "allowance-trend",
            title: "Allowance",
            headline: "\(MoneyFormat.string(spent.rounded2)) recorded of \(MoneyFormat.string(available.rounded2)) available",
            detail: unspent > 0
                ? "\(MoneyFormat.string(unspent)) is still available — not spent, and never counted as spent."
                : "Across the last \(pastPaydays.count) pay period\(pastPaydays.count == 1 ? "" : "s").",
            tone: .neutral,
            symbol: "wallet.pass"
        )
    }
}
