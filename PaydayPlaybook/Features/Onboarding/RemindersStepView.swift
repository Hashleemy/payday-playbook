import SwiftUI
import SwiftData
import UserNotifications

/// Step 8 — dates and reminders (§4.10, F-11). Shows the paydays and due
/// dates the app just derived, explains what each reminder would say, and
/// only then asks for permission. Denial leaves everything working.
struct RemindersStepView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler
    @Query private var debts: [DebtAccount]
    @Query private var obligations: [RecurringObligation]

    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var requesting = false
    @State private var decision: PermissionDecision = .undecided

    enum PermissionDecision {
        case undecided
        case granted
        case denied
    }

    var body: some View {
        OnboardingScaffold(
            title: "Your dates",
            subtitle: "Here's the rhythm the app just worked out from your answers.",
            continueTitle: "Continue",
            continueIdentifier: "onboarding.remindersContinue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            paydaysSection
            dueDatesSection
            remindersSection
            permissionSection
        }
        .task {
            await notificationScheduler.refreshAuthorizationStatus()
        }
    }

    // MARK: - Generated dates

    private var upcomingPaydays: [Date] {
        guard let schedule = try? IncomeRepository(context: modelContext).activeSchedule() else {
            return []
        }
        let snapshot = PlanInputSnapshot(
            calculationVersion: PlanContract.currentCalculationVersion,
            cadence: schedule.cadence,
            monthlyPayDay: schedule.monthlyDay,
            semimonthlyPayDay1: schedule.semimonthlyFirstDay,
            semimonthlyPayDay2: schedule.semimonthlySecondDay,
            nextPayday: schedule.anchorPayday,
            baseTakeHome: schedule.baseTakeHome,
            incomeChanges: [],
            spendingStartingBalance: .zero,
            protectedFloor: .zero,
            allowanceCap: .zero,
            firstCheckBufferAdd: .zero,
            obligations: [],
            debts: [],
            paycheckCap: PlanInputSnapshot.defaultPaycheckCap,
            timeZoneID: TimeZone.current.identifier
        )
        guard let cadence = try? PlanGenerationService.planningCadence(from: snapshot) else {
            return []
        }
        return PayScheduleGenerator.paydays(
            cadence: cadence, anchor: schedule.anchorPayday, count: 6
        )
    }

    private var paydaysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your next paydays")
                .font(.headline)
            if upcomingPaydays.isEmpty {
                Text("Add your income to see your paydays.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(upcomingPaydays.enumerated()), id: \.offset) { index, date in
                    SetupSummaryRow(label: "Payday \(index + 1)", value: DateMath.mediumString(date))
                }
                Text("They keep going from here on the same rhythm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dueDatesSection: some View {
        let dated = debts.filter { !$0.isArchived && $0.dueDayOfMonth != nil }
        let datedBills = obligations.filter { !$0.isArchived && $0.dueDay != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Due dates you entered")
                .font(.headline)
            if dated.isEmpty && datedBills.isEmpty {
                Text("You haven't set any due dates yet. You can add them any time from the Debts tab — the calendar and reminders follow immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(dated) { debt in
                    SetupSummaryRow(
                        label: debt.displayName,
                        value: "the \(SetupDayField.dayLabel(debt.dueDayOfMonth ?? 1))"
                    )
                }
                ForEach(datedBills) { bill in
                    SetupSummaryRow(
                        label: bill.name,
                        value: "the \(SetupDayField.dayLabel(bill.dueDay ?? 1))"
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What reminders would do")
                .font(.headline)
            Label("Payday morning at 8:00 AM — today's play", systemImage: "sun.max")
            Label("Payday evening at 7:00 PM — only if the check-in is still open", systemImage: "moon")
            Label("Due dates — three days ahead and the day of, at 9:00 AM", systemImage: "calendar")
            Label("Sunday at 6:00 PM — a short weekly summary", systemImage: "chart.line.uptrend.xyaxis")
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Permission, asked in context

    @ViewBuilder
    private var permissionSection: some View {
        switch notificationScheduler.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Reminders are on. You can change any of them in Settings.", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.mint)
        case .denied:
            deniedNotice
        default:
            VStack(alignment: .leading, spacing: 10) {
                if decision == .denied {
                    deniedNotice
                } else {
                    Button {
                        requestPermission()
                    } label: {
                        if requesting {
                            SwiftUI.ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Text("Turn on reminders")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(requesting)
                    .accessibilityIdentifier("onboarding.enableNotifications")

                    Text("Optional. Everything in the app works without them — you'll still see today's play when you open it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var deniedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reminders are off", systemImage: "bell.slash")
                .font(.subheadline.weight(.medium))
            Text("That's fine — the app is fully usable without them. If you change your mind, iOS Settings can turn them back on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open iOS Settings", destination: url)
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding.openSettings")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.notificationsDenied")
    }

    private func requestPermission() {
        requesting = true
        Task {
            let granted = await notificationScheduler.requestAuthorization()
            requesting = false
            decision = granted ? .granted : .denied
        }
    }
}
