import Foundation
import SwiftData
import UserNotifications

/// Owns the app's local notifications (F-11, V2-11).
///
/// The desired schedule is computed by the pure `NotificationPlanner` and
/// reconciled against the pending requests, so rescheduling replaces rather
/// than duplicates: identifiers are stable and namespaced, changed copy is
/// re-added, and requests this app owns but no longer wants are cancelled —
/// including identifiers from earlier app versions.
///
/// Permission is requested only after the value explanation in onboarding or
/// Settings. If it is denied the app stays fully usable and Settings offers a
/// route to iOS Settings; scheduling simply becomes a no-op.
@MainActor
final class NotificationScheduler: ObservableObject {
    /// 0.1.x route spelling kept for the `userInfo` key contract.
    typealias Route = NotificationRoute

    static let routeKey = "route"
    static let referenceKey = "reference"
    static let fingerprintKey = "fingerprint"

    /// Every state that can invalidate the pending set (V3-07). Naming them
    /// makes the contract checkable — the device pass and the diagnostics
    /// screen can both answer "which of these has actually run?" — and gives
    /// each call site one obvious thing to pass.
    enum ReconcileTrigger: String, CaseIterable {
        case launch
        case foreground
        case migration
        case permissionChange
        case dueDateEdit
        case planActivation
        case archiveOrPayoff
        case timeZoneChange
        case appSettingsChange
        case checkInCompleted
        case manualDiagnostics
    }

    /// Why a pass scheduled nothing. Distinguishes "no permission" from "no
    /// work to do", which look identical from outside and mean very
    /// different things during a device check.
    enum SkipReason: String {
        case notAuthorized
        case scheduleUnavailable
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Last reconcile outcome, for Settings diagnostics and tests.
    @Published private(set) var lastReconciliation: NotificationReconciliation?
    /// Requests the rolling-window cap left unscheduled at the last pass.
    @Published private(set) var lastDroppedByCap = 0
    /// What prompted the last pass, and why it scheduled nothing if it did.
    @Published private(set) var lastTrigger: ReconcileTrigger?
    @Published private(set) var lastSkipReason: SkipReason?

    private let center: NotificationCenterProtocol

    init(center: NotificationCenterProtocol = UNUserNotificationCenter.current()) {
        self.center = center
    }

    // MARK: - Authorization

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.authorizationStatus()
    }

    #if DEBUG
    /// Read-only snapshot of what is actually pending, for the debug
    /// diagnostics screen. The device checklist has to answer "did that edit
    /// leave a duplicate behind?", and that is not a question the lock screen
    /// can answer — a stale trigger looks exactly like a correct one until it
    /// fires on the wrong day. Reads only; schedules and cancels nothing.
    func pendingSnapshot() async -> [UNNotificationRequest] {
        await center.pendingRequests()
    }
    #endif

    /// Requests permission. Callers must have shown the value explanation
    /// first (onboarding step 9 / Settings → Reminders).
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = await center.requestPermission(options: [.alert, .badge, .sound])
        await refreshAuthorizationStatus()
        return granted
    }

    /// Requests permission and immediately reconciles, so a grant produces a
    /// schedule without waiting for the next foreground (V3-07: permission
    /// change is a reconcile trigger). A denial reconciles too — the pass
    /// records why it scheduled nothing instead of leaving the diagnostics
    /// blank.
    @discardableResult
    func requestAuthorizationAndReconcile(
        context: ModelContext,
        dateProvider: DateProviding
    ) async -> Bool {
        let granted = await requestAuthorization()
        await rescheduleAll(context: context, dateProvider: dateProvider, trigger: .permissionChange)
        return granted
    }

    /// True when the system will actually deliver what we schedule.
    /// Provisional authorization counts: quiet delivery is still delivery.
    static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    // MARK: - Reconciliation

    /// Recomputes the desired schedule and applies the difference.
    ///
    /// Runs after every state that can invalidate the pending set (V3-07):
    /// launch and foreground, migration, permission changes, due-rule edits,
    /// plan activation and replacement, archive/payoff, time-zone changes,
    /// reminder-settings edits, and check-in completion — see
    /// `ReconcileTrigger`.
    ///
    /// The pass is idempotent by construction: `NotificationPlanner.plan` is
    /// a pure function of the store, identifiers are stable, and the diff is
    /// taken against what is actually pending. Running it twice with nothing
    /// changed in between produces an empty add list and an empty remove
    /// list, so a redundant trigger costs a read and nothing else.
    func rescheduleAll(
        context: ModelContext,
        dateProvider: DateProviding,
        trigger: ReconcileTrigger = .foreground
    ) async {
        lastTrigger = trigger
        authorizationStatus = await center.authorizationStatus()
        guard Self.canSchedule(authorizationStatus) else {
            // Denied or undetermined: nothing is scheduled, and nothing
            // pending is touched — the user's data and the app are
            // unaffected, and the app stays fully usable (V3-16). Anything
            // left pending from before a revocation cannot fire while
            // permission is off, and the first pass after a re-grant removes
            // whatever the current schedule no longer wants.
            lastSkipReason = .notAuthorized
            return
        }

        let plan: NotificationPlanner.Plan
        do {
            plan = NotificationPlanner.plan(
                try NotificationPlanner.makeInput(context: context, dateProvider: dateProvider)
            )
        } catch {
            // Scheduling must never take the app down or wipe a good
            // schedule; the existing requests stand and the next trigger
            // point retries. Cancelling on a read failure would be the worst
            // outcome — a store hiccup would silently disarm every reminder.
            lastSkipReason = .scheduleUnavailable
            return
        }
        lastSkipReason = nil

        let pending = await center.pendingRequests().map {
            (identifier: $0.identifier, fingerprint: $0.content.userInfo[Self.fingerprintKey] as? String)
        }
        let reconciliation = NotificationPlanner.reconcile(desired: plan.notifications, pending: pending)

        if !reconciliation.toRemove.isEmpty {
            center.removePending(identifiers: reconciliation.toRemove)
        }
        for entry in reconciliation.toAdd {
            try? await center.add(makeRequest(entry))
        }

        lastReconciliation = reconciliation
        lastDroppedByCap = plan.droppedByCap
    }

    private func makeRequest(_ entry: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = entry.title
        content.body = entry.body
        content.sound = .default
        content.userInfo = [
            Self.routeKey: entry.route.rawValue,
            Self.referenceKey: entry.reference,
            Self.fingerprintKey: entry.fingerprint
        ]
        // Calendar components, not an absolute instant: the reminder keeps
        // its intended local time if the user changes time zone or a DST
        // transition lands in between.
        let trigger = UNCalendarNotificationTrigger(dateMatching: entry.dateComponents, repeats: false)
        return UNNotificationRequest(identifier: entry.identifier, content: content, trigger: trigger)
    }

    /// Cancels a payday's reminders the moment its check-in completes, so
    /// the evening nudge cannot fire for finished work. A full reconcile
    /// follows; this is the immediate half.
    func cancelPaydayReminders(itemID: UUID) {
        center.removePending(identifiers: [
            NotificationFamily.paydayMorning.identifier(entity: itemID.uuidString),
            NotificationFamily.paydayEvening.identifier(entity: itemID.uuidString)
        ])
    }

    /// Cancels every request this app owns. Used when the user turns all
    /// reminders off; requests from other sources are never touched.
    func cancelAllOwned() async {
        let owned = await center.pendingRequests()
            .map(\.identifier)
            .filter(NotificationFamily.owns)
        guard !owned.isEmpty else { return }
        center.removePending(identifiers: owned)
    }
}

/// The slice of `UNUserNotificationCenter` this app uses, so the scheduler
/// can be driven by a fake in tests (the real center cannot be exercised in
/// a unit-test process without a running app and granted permission).
protocol NotificationCenterProtocol: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestPermission(options: UNAuthorizationOptions) async -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(identifiers: [String])
}

extension UNUserNotificationCenter: NotificationCenterProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func requestPermission(options: UNAuthorizationOptions) async -> Bool {
        (try? await requestAuthorization(options: options)) ?? false
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        await pendingNotificationRequests()
    }

    func removePending(identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
