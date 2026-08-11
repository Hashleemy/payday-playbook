import Foundation
import SwiftData
import UserNotifications

/// Schedules local notifications with stable identifiers so reschedules
/// replace rather than duplicate. Content stays generic on the lock screen
/// unless the user enables detailed previews. Main-actor bound: it reads the
/// main-actor SwiftData context when rebuilding the schedule.
@MainActor
final class NotificationScheduler: ObservableObject {
    enum Route: String {
        case checkIn = "checkin"
        case cardDetail = "card"
        case today = "today"
        case progress = "progress"
        case milestone = "milestone"
    }

    static let routeKey = "route"
    static let referenceKey = "reference"

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    /// Rolling scheduling window; iOS caps pending requests at 64.
    private let windowDays = 45

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            await refreshAuthorizationStatus()
            return false
        }
    }

    /// Rebuilds every pending request from current data. Safe to call often;
    /// identifiers are stable so this replaces rather than duplicates. The
    /// replacement list is built first — existing requests are only cleared
    /// once a full new set exists, so a failure never leaves zero reminders.
    func rescheduleAll(context: ModelContext, dateProvider: DateProviding) async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        do {
            let requests = try buildRequests(context: context, dateProvider: dateProvider)
            center.removeAllPendingNotificationRequests()
            for request in requests {
                try? await center.add(request)
            }
        } catch {
            // Notification scheduling must never crash the app; the previous
            // schedule stays in place and the next trigger point will retry.
        }
    }

    private func buildRequests(context: ModelContext, dateProvider: DateProviding) throws -> [UNNotificationRequest] {
        var requests: [UNNotificationRequest] = []
        let preferences = try context.fetch(FetchDescriptor<NotificationPreference>())
        func pref(_ kind: NotificationKind) -> NotificationPreference? {
            preferences.first { $0.type == kind }
        }

        let today = DateMath.startOfDay(dateProvider.now)
        let windowEnd = DateMath.addingDays(windowDays, to: today)

        guard let plan = try PlanSeeder.currentPlan(context: context) else { return requests }
        let planID = plan.id
        let planItems = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )
        let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
        let completedIDs = Set(
            checkIns.filter { $0.status == .completed || $0.status == .needsAttention }
                .map(\.paydayPlanItemID)
        )

        // Payday morning + evening-if-incomplete.
        if let morning = pref(.paydayMorning), morning.enabled {
            for item in planItems where !completedIDs.contains(item.id) {
                let day = DateMath.startOfDay(item.date)
                guard day >= today, day <= windowEnd else { continue }
                requests.append(makeRequest(
                    id: "payday-morning-\(item.sequenceNumber)",
                    title: "Today's play",
                    body: morning.detailedLockScreenContent
                        ? "Payday #\(item.sequenceNumber): keep \(MoneyFormat.string(item.plannedC1Keep)), move \(MoneyFormat.string(item.plannedC2Transfer)), pay cards \(MoneyFormat.string(item.plannedCardBudget))."
                        : "Your payday check-in is ready.",
                    date: day, hour: morning.hour, minute: morning.minute,
                    route: .checkIn, reference: item.id.uuidString
                ))
            }
        }
        if let evening = pref(.paydayEveningIncomplete), evening.enabled {
            for item in planItems where !completedIDs.contains(item.id) {
                let day = DateMath.startOfDay(item.date)
                guard day >= today, day <= windowEnd else { continue }
                requests.append(makeRequest(
                    id: "payday-evening-\(item.sequenceNumber)",
                    title: "Payday check-in",
                    body: "Today's payday check-in is still open.",
                    date: day, hour: evening.hour, minute: evening.minute,
                    route: .checkIn, reference: item.id.uuidString
                ))
            }
        }

        // Card due dates within the window.
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let calendar = DateMath.calendar
        let dueSoon = pref(.cardDueSoon)
        let dueToday = pref(.cardDueToday)
        for debt in debts where !debt.isArchived {
            guard let dueDay = debt.dueDayOfMonth else { continue }
            for monthOffset in 0...2 {
                guard let monthDate = calendar.date(byAdding: .month, value: monthOffset, to: today) else { continue }
                var components = calendar.dateComponents([.year, .month], from: monthDate)
                components.day = min(dueDay, 28)
                guard let dueDate = calendar.date(from: components) else { continue }
                let dueDayStart = DateMath.startOfDay(dueDate)
                let monthTag = String(format: "%04d%02d", components.year ?? 0, components.month ?? 0)
                if let dueSoon, dueSoon.enabled {
                    let soonDate = DateMath.addingDays(-max(dueSoon.leadDays, 1), to: dueDayStart)
                    if soonDate >= today && soonDate <= windowEnd {
                        requests.append(makeRequest(
                            id: "due-soon-\(debt.planID)-\(monthTag)",
                            title: "Card due soon",
                            body: dueSoon.detailedLockScreenContent
                                ? "\(debt.displayName) is due on day \(dueDay)."
                                : "A card payment is due soon.",
                            date: soonDate, hour: dueSoon.hour, minute: dueSoon.minute,
                            route: .cardDetail, reference: debt.planID
                        ))
                    }
                }
                if let dueToday, dueToday.enabled, dueDayStart >= today, dueDayStart <= windowEnd {
                    requests.append(makeRequest(
                        id: "due-today-\(debt.planID)-\(monthTag)",
                        title: "Card due today",
                        body: dueToday.detailedLockScreenContent
                            ? "\(debt.displayName) is due today."
                            : "A card payment is due today.",
                        date: dueDayStart, hour: dueToday.hour, minute: dueToday.minute,
                        route: .cardDetail, reference: debt.planID
                    ))
                }
            }
        }

        // Weekly summary: next Sundays in window.
        if let weekly = pref(.weeklySummary), weekly.enabled {
            var cursor = today
            var count = 0
            while cursor <= windowEnd && count < 8 {
                if calendar.component(.weekday, from: cursor) == 1 {
                    requests.append(makeRequest(
                        id: "weekly-summary-\(Int(cursor.timeIntervalSince1970))",
                        title: "Weekly summary",
                        body: "See this week's progress and the next play.",
                        date: cursor, hour: weekly.hour, minute: weekly.minute,
                        route: .progress, reference: ""
                    ))
                    count += 1
                }
                cursor = DateMath.addingDays(1, to: cursor)
            }
        }

        // Milestones approaching (one payday of notice by default).
        if let milestonePref = pref(.milestoneApproaching), milestonePref.enabled {
            let milestones = try context.fetch(FetchDescriptor<Milestone>())
            for milestone in milestones where milestone.achievedDate == nil {
                guard let target = milestone.forecastDate ?? milestone.baselineDate else { continue }
                let leadPaydays = max(milestonePref.leadDays, 1)
                let noticeDate = DateMath.addingDays(-leadPaydays * plan.payFrequencyDays, to: DateMath.startOfDay(target))
                guard noticeDate >= today, noticeDate <= windowEnd else { continue }
                requests.append(makeRequest(
                    id: "milestone-\(milestone.id.uuidString)",
                    title: "Milestone ahead",
                    body: milestonePref.detailedLockScreenContent
                        ? "\(milestone.title) is projected for \(DateMath.mediumString(target))."
                        : "A payoff milestone is coming up.",
                    date: noticeDate, hour: milestonePref.hour, minute: milestonePref.minute,
                    route: .milestone, reference: milestone.id.uuidString
                ))
            }
        }

        return requests
    }

    private func makeRequest(
        id: String, title: String, body: String,
        date: Date, hour: Int, minute: Int,
        route: Route, reference: String
    ) -> UNNotificationRequest {
        var components = DateMath.calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.routeKey: route.rawValue, Self.referenceKey: reference]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    /// Immediately removes the evening reminder once a payday completes.
    func cancelEveningReminder(sequenceNumber: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [
            "payday-evening-\(sequenceNumber)",
            "payday-morning-\(sequenceNumber)"
        ])
    }
}
