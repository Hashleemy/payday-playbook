#if DEBUG
import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Pure analysis

/// A pending request reduced to the parts that matter for diagnosis, so the
/// analysis below is testable without a notification centre.
struct PendingNotificationSummary: Equatable {
    let identifier: String
    let title: String
    let body: String
    /// Resolved next fire moment, when the trigger can tell us one.
    let fireDate: Date?
    /// Whether this app scheduled it — includes the 0.1.x spellings.
    let isOurs: Bool

    init(identifier: String, title: String, body: String, fireDate: Date?) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.isOurs = NotificationFamily.owns(identifier)
    }

    init(request: UNNotificationRequest) {
        let trigger = request.trigger as? UNCalendarNotificationTrigger
        self.init(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body,
            fireDate: trigger?.nextTriggerDate()
        )
    }
}

/// What the device pass is actually looking for.
///
/// Exact-identifier duplicates cannot exist — `UNUserNotificationCenter`
/// replaces in place, which is the property the reconciler relies on. The real
/// failure modes are subtler and both invisible on a lock screen: a request
/// left behind under the 0.1.x identifier scheme (which would fire *alongside*
/// its v2 replacement rather than being replaced by it), and two differently
/// identified requests that say the same thing at the same moment.
enum NotificationDiagnostics {
    enum Finding: Equatable {
        /// A request under a 0.1.x prefix. Post-upgrade these must all be gone;
        /// each one is a reminder that will fire twice.
        case legacyScheme(identifier: String)
        /// Requests that would reach the user as the same notification twice.
        case duplicateContent(title: String, fireDate: Date?, identifiers: [String])
        /// Not ours. Informational — the reconciler never touches these.
        case foreign(identifier: String)

        var isProblem: Bool {
            switch self {
            case .legacyScheme, .duplicateContent: return true
            case .foreign: return false
            }
        }
    }

    /// The 0.1.x spellings. `NotificationFamily.ownedPrefixes` deliberately
    /// still claims these so reconciliation can *remove* them; anything still
    /// pending under one after an upgrade is a defect.
    static let legacyPrefixes = ["due-soon-", "due-today-", "milestone-"]

    static func isLegacy(_ identifier: String) -> Bool {
        // `milestone-` also prefixes `milestone-approaching-`, which is current.
        if identifier.hasPrefix(NotificationFamily.milestoneApproaching.rawValue + "-") {
            return false
        }
        return legacyPrefixes.contains { identifier.hasPrefix($0) }
    }

    static func findings(for pending: [PendingNotificationSummary]) -> [Finding] {
        var findings: [Finding] = []

        for summary in pending where isLegacy(summary.identifier) {
            findings.append(.legacyScheme(identifier: summary.identifier))
        }

        // Same words, same minute, more than one request: whatever the
        // identifiers say, the user is getting it twice.
        let ours = pending.filter(\.isOurs)
        let grouped = Dictionary(grouping: ours) { summary in
            ContentKey(title: summary.title, body: summary.body, fireDate: summary.fireDate)
        }
        for (key, group) in grouped where group.count > 1 {
            findings.append(.duplicateContent(
                title: key.title,
                fireDate: key.fireDate,
                identifiers: group.map(\.identifier).sorted()
            ))
        }

        for summary in pending where !summary.isOurs {
            findings.append(.foreign(identifier: summary.identifier))
        }

        return findings
    }

    private struct ContentKey: Hashable {
        let title: String
        let body: String
        /// Minute resolution: the fire moment the scheduler controls.
        let minute: Date?

        init(title: String, body: String, fireDate: Date?) {
            self.title = title
            self.body = body
            self.minute = fireDate.map {
                Calendar.current.date(
                    from: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: $0
                    )
                ) ?? $0
            }
        }

        var fireDate: Date? { minute }
    }
}

// MARK: - Screen

/// Debug-only window onto the notification schedule (device checklist items
/// 1, 2 and 5). Read-only apart from an explicit "Reconcile now", which runs
/// the same reconcile a foreground would.
struct NotificationDiagnosticsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @State private var pending: [PendingNotificationSummary] = []
    @State private var findings: [NotificationDiagnostics.Finding] = []
    @State private var isWorking = false

    private var scheduler: NotificationScheduler { appEnvironment.notificationScheduler }

    /// iOS silently drops requests past 64; the planner caps at 60 for headroom.
    private let systemLimit = 64

    var body: some View {
        List {
            statusSection
            findingsSection
            pendingSection
        }
        .navigationTitle("Notification diagnostics")
        .toolbar {
            Button("Reconcile now") { Task { await reconcile() } }
                .disabled(isWorking)
        }
        .task { await refresh() }
    }

    private var statusSection: some View {
        Section("Status") {
            row("Authorization", describe(scheduler.authorizationStatus))
            row("Can schedule", NotificationScheduler.canSchedule(scheduler.authorizationStatus) ? "yes" : "no")
            LabeledContent("Pending") {
                Text("\(pending.count) of \(systemLimit)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(pending.count >= 60 ? .orange : .primary)
            }
            row("Dropped by cap", "\(scheduler.lastDroppedByCap)")
            if let reconciliation = scheduler.lastReconciliation {
                row(
                    "Last reconcile",
                    "+\(reconciliation.toAdd.count) −\(reconciliation.toRemove.count) =\(reconciliation.unchanged)"
                )
            } else {
                row("Last reconcile", "none this launch")
            }
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        let problems = findings.filter(\.isProblem)
        Section("Findings") {
            if problems.isEmpty {
                Label("No duplicates and no 0.1.x leftovers", systemImage: "checkmark.circle")
                    .font(.footnote)
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                switch finding {
                case let .legacyScheme(identifier):
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("0.1.x identifier still pending — would fire twice")
                            Text(identifier).font(.caption2.monospaced())
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .font(.footnote)
                case let .duplicateContent(title, fireDate, identifiers):
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Duplicate: \"\(title)\" at \(describe(fireDate))")
                            ForEach(identifiers, id: \.self) {
                                Text($0).font(.caption2.monospaced())
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .font(.footnote)
                case let .foreign(identifier):
                    Label {
                        Text("Not ours, left alone: \(identifier)").font(.caption2.monospaced())
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var pendingSection: some View {
        Section("Pending, soonest first") {
            if pending.isEmpty {
                Text("Nothing scheduled.").font(.footnote)
            }
            ForEach(pending, id: \.identifier) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(describe(item.fireDate)).font(.footnote.monospaced().bold())
                    Text(item.identifier).font(.caption2.monospaced())
                    Text(item.title).font(.caption2)
                    Text(item.body).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).font(.footnote.monospaced()) }
    }

    // MARK: - Actions

    private func refresh() async {
        isWorking = true
        defer { isWorking = false }
        await scheduler.refreshAuthorizationStatus()
        let requests = await scheduler.pendingSnapshot()
        let summaries = requests
            .map(PendingNotificationSummary.init(request:))
            .sorted {
                switch ($0.fireDate, $1.fireDate) {
                case let (lhs?, rhs?): return lhs == rhs ? $0.identifier < $1.identifier : lhs < rhs
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return $0.identifier < $1.identifier
                }
            }
        pending = summaries
        findings = NotificationDiagnostics.findings(for: summaries)
    }

    private func reconcile() async {
        isWorking = true
        await scheduler.rescheduleAll(context: modelContext, dateProvider: appEnvironment.dateProvider, trigger: .manualDiagnostics)
        isWorking = false
        await refresh()
    }

    private func describe(_ date: Date?) -> String {
        guard let date else { return "no fire date" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
#endif
