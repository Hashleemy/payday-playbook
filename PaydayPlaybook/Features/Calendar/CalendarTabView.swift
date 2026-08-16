import SwiftUI
import SwiftData

/// Month / week / agenda calendar with event markers, filters, a
/// selected-day play-by-play, and typed deep links (F-07, V2-11, V2-12).
/// Status is always icon + text — color is reinforcement, never the signal.
struct CalendarTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query private var checkIns: [PaydayCheckIn]
    @Query private var ledgerEntries: [LedgerEntry]

    enum Mode: String, CaseIterable, Identifiable {
        case month = "Month"
        case week = "Week"
        case agenda = "Agenda"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .month
    @State private var displayedMonth: Date = Date()
    @State private var selectedDay: Date?
    @State private var filter: CalendarEventService.Filter = .all
    @State private var events: [CalendarEventService.Event] = []
    @State private var checkInItem: PaydayPlanItem?
    @State private var entryDetail: LedgerEntry?
    @State private var milestoneDetail: Milestone?
    @State private var showAddSheet = false
    @State private var missingTargetMessage: String?

    private var calendar: Calendar { DateMath.calendar }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                switch mode {
                case .month:
                    monthGrid
                    Divider()
                    selectedDayPanel
                case .week:
                    weekStrip
                    Divider()
                    selectedDayPanel
                case .agenda:
                    agendaList
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Jump to Today") { jump(to: appEnvironment.dateProvider.now) }
                        Button("Jump to Debt-Free Date") { jumpToDebtFree() }
                    } label: {
                        Image(systemName: "arrow.uturn.forward.circle")
                    }
                    .accessibilityLabel("Jump to date")
                }
            }
            .onAppear {
                // Only center on today the first time the tab is shown;
                // re-appearing must not throw away the month the user was
                // browsing, or a deep link that just selected a due date.
                if selectedDay == nil {
                    displayedMonth = DateMath.startOfDay(appEnvironment.dateProvider.now)
                    selectedDay = DateMath.startOfDay(appEnvironment.dateProvider.now)
                }
                reload()
                revealObligation(router.pendingObligationID)
            }
            .onChange(of: displayedMonth) { _, _ in reload() }
            .onChange(of: mode) { _, _ in reload() }
            .onChange(of: router.pendingObligationID) { _, obligationID in
                revealObligation(obligationID)
            }
            .onChange(of: checkIns.count) { _, _ in reload() }
            .onChange(of: ledgerEntries.count) { _, _ in reload() }
            .sheet(item: $checkInItem, onDismiss: reload) { item in
                CheckInFlowView(planItem: item)
            }
            .sheet(item: $entryDetail) { entry in
                LedgerEntryDetailSheet(entry: entry)
            }
            .sheet(item: $milestoneDetail) { milestone in
                MilestoneDetailSheet(milestone: milestone) {
                    milestoneDetail = nil
                    router.selectedTab = .progress
                }
            }
            .sheet(isPresented: $showAddSheet, onDismiss: reload) {
                QuickAddSheet()
            }
            .alert(
                "Not available",
                isPresented: Binding(
                    get: { missingTargetMessage != nil },
                    set: { if !$0 { missingTargetMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(missingTargetMessage ?? "")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Picker("Filter", selection: $filter) {
                ForEach(CalendarEventService.Filter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(monthTitle)
                    .font(.headline)
                Spacer()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next month")
            }
            .padding(.horizontal)

            let symbols = calendar.veryShortStandaloneWeekdaySymbols
            HStack {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(monthDays, id: \.self) { day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Week strip

    private var weekStrip: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    shiftWeek(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Previous week")
                Spacer()
                Text(weekTitle)
                    .font(.headline)
                Spacer()
                Button {
                    shiftWeek(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next week")
            }
            .padding(.horizontal)

            HStack(spacing: 2) {
                ForEach(weekDays, id: \.self) { day in
                    VStack(spacing: 2) {
                        Text(shortWeekdaySymbol(day))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        dayCell(day)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let dayEvents = eventsByDay[day] ?? []
        let isSelected = selectedDay.map { DateMath.isSameDay($0, day) } ?? false
        let isToday = DateMath.isSameDay(day, appEnvironment.dateProvider.now)
        let needsAttention = dayEvents.contains { $0.status == .needsAttention }
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                HStack(spacing: 2) {
                    if needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(Set(dayEvents.map(\.kind))).sorted { $0.dayOrder < $1.dayOrder }.prefix(needsAttention ? 2 : 3), id: \.self) { kind in
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 7))
                            .foregroundStyle(markerColor(kind))
                    }
                }
                .frame(height: 10)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                // Needs-attention ring: paired with the triangle icon above,
                // so the state reads without color perception.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(needsAttention ? Color.orange : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(day, events: dayEvents))
    }

    private func markerColor(_ kind: CalendarEventService.EventKind) -> Color {
        switch kind {
        case .payday: return .blue
        case .transfer: return .teal
        case .reserve: return .indigo
        case .debtPayment: return .purple
        case .debtDue: return Color(red: 0.94, green: 0.45, blue: 0.40)
        case .obligationDue: return .brown
        case .milestone: return .mint
        case .entry: return .gray
        case .reforecast: return .cyan
        }
    }

    private func dayAccessibilityLabel(_ day: Date, events: [CalendarEventService.Event]) -> String {
        var label = DateMath.mediumString(day)
        if events.isEmpty {
            label += ", no events"
        } else {
            label += ", " + events.map(\.accessibilityDescription).joined(separator: ", ")
        }
        return label
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private var weekTitle: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        return "\(DateMath.mediumString(first)) – \(DateMath.mediumString(last))"
    }

    private func shortWeekdaySymbol(_ day: Date) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return symbols[calendar.component(.weekday, from: day) - 1]
    }

    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let firstDay = interval.start
        let dayCount = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
        let firstWeekday = calendar.component(.weekday, from: firstDay)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            days.append(calendar.date(byAdding: .day, value: offset, to: firstDay).map(DateMath.startOfDay))
        }
        return days
    }

    private var weekDays: [Date] {
        let anchor = selectedDay ?? DateMath.startOfDay(appEnvironment.dateProvider.now)
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return [] }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: interval.start).map(DateMath.startOfDay)
        }
    }

    private var filteredEvents: [CalendarEventService.Event] {
        events.filter { filter.includes($0) }
    }

    private var eventsByDay: [Date: [CalendarEventService.Event]] {
        Dictionary(grouping: filteredEvents) { DateMath.startOfDay($0.date) }
    }

    // MARK: - Selected day panel

    private var selectedDayPanel: some View {
        List {
            if let selectedDay {
                let dayEvents = eventsByDay[DateMath.startOfDay(selectedDay)] ?? []
                Section(DateMath.mediumString(selectedDay)) {
                    if dayEvents.isEmpty {
                        Text("Nothing planned or recorded.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dayEvents) { event in
                        eventRow(event)
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Entry", systemImage: "plus.circle")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var agendaList: some View {
        List {
            let days = eventsByDay.keys.sorted()
            ForEach(days, id: \.self) { day in
                Section(DateMath.mediumString(day)) {
                    ForEach(eventsByDay[day] ?? []) { event in
                        eventRow(event)
                    }
                }
            }
            if filteredEvents.isEmpty {
                EmptyStateView(
                    title: "No events",
                    message: "Nothing in this month matches the filter.",
                    symbolName: "calendar"
                )
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEventService.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.symbolName)
                .foregroundStyle(markerColor(event.kind))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    Text(event.kind.label)
                    Text("·")
                    // Status as icon + text, never color alone.
                    Image(systemName: event.status.symbolName)
                        .font(.caption2)
                    Text(event.status.label)
                }
                .font(.caption)
                .foregroundStyle(event.status == .needsAttention ? Color.orange : Color.secondary)
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if event.link != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(event) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.accessibilityDescription)
        .accessibilityAddTraits(event.link != nil ? .isButton : [])
        .accessibilityHint(actionLabel(event) ?? "")
    }

    private func actionLabel(_ event: CalendarEventService.Event) -> String? {
        switch event.link {
        case .checkIn: return "Open check-in"
        case .debt: return "Open debt"
        case .obligation: return "Show this bill's due date"
        case .entry: return "Open entry"
        case .milestone: return "View milestone"
        case nil: return nil
        }
    }

    /// Typed deep-link dispatch. Every target is resolved against the store
    /// first; an archived or deleted entity gets a calm explanation instead
    /// of a dead tap (V2-11).
    private func open(_ event: CalendarEventService.Event) {
        guard let link = event.link else { return }
        let service = appEnvironment.calendarService(context: modelContext)
        guard let resolution = try? service.resolve(link) else {
            missingTargetMessage = "That item can't be opened right now."
            return
        }
        switch resolution {
        case .openCheckIn(let itemID):
            checkInItem = (try? modelContext.fetch(FetchDescriptor<PaydayPlanItem>()))?
                .first { $0.id == itemID }
        case .openDebt(let debtID, let planID):
            // Prefer entity identity; the letter is only a fallback for links
            // that never carried a UUID.
            if let debtID {
                router.pendingDebtID = debtID
            } else {
                router.pendingDebtPlanID = planID
            }
            router.selectedTab = .debts
        case .openObligation(let obligationID):
            revealObligation(obligationID)
        case .openEntry(let entryID):
            entryDetail = (try? modelContext.fetch(FetchDescriptor<LedgerEntry>()))?
                .first { $0.id == entryID }
        case .openMilestone(let milestoneID):
            milestoneDetail = (try? modelContext.fetch(FetchDescriptor<Milestone>()))?
                .first { $0.id == milestoneID }
        case .unavailable(let message):
            missingTargetMessage = message
        }
    }

    // MARK: - Actions

    /// Moves the month *and* the selection: the selected-day panel and the
    /// week strip both read from `selectedDay`, so leaving it behind in the
    /// previous month would show an empty day outside the loaded window.
    /// Landing on today when the new month contains it, otherwise the 1st.
    private func shiftMonth(_ direction: Int) {
        guard let next = calendar.date(byAdding: .month, value: direction, to: displayedMonth) else { return }
        displayedMonth = next
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        if calendar.isDate(today, equalTo: next, toGranularity: .month) {
            selectedDay = today
        } else if let interval = calendar.dateInterval(of: .month, for: next) {
            selectedDay = DateMath.startOfDay(interval.start)
        }
    }

    private func shiftWeek(_ direction: Int) {
        let anchor = selectedDay ?? DateMath.startOfDay(appEnvironment.dateProvider.now)
        if let next = calendar.date(byAdding: .day, value: 7 * direction, to: anchor) {
            selectedDay = DateMath.startOfDay(next)
            displayedMonth = DateMath.startOfDay(next)
        }
    }

    /// A bill-due deep link selects that obligation's next occurrence, so
    /// the day panel opens on the bill the reminder was about. An
    /// obligation that was archived or deleted in the meantime leaves the
    /// calendar on today rather than jumping somewhere arbitrary.
    private func revealObligation(_ obligationID: UUID?) {
        guard let obligationID else { return }
        router.pendingObligationID = nil
        // Resolve through the same path a tapped calendar row uses, so a
        // bill archived or deleted since the reminder was scheduled gets the
        // same calm explanation instead of a tap that appears to do nothing
        // (V3-07).
        let service = appEnvironment.calendarService(context: modelContext)
        switch (try? service.resolve(.obligation(obligationID: obligationID))) {
        case .openObligation(let id):
            let obligations = (try? modelContext.fetch(FetchDescriptor<RecurringObligation>())) ?? []
            guard let obligation = obligations.first(where: { $0.id == id }) else { return }
            guard let next = obligation.dueRule.nextOccurrence(onOrAfter: appEnvironment.dateProvider.now) else {
                missingTargetMessage = "This bill has no due date set, so there's nothing to show on the calendar."
                return
            }
            jump(to: next)
        case .unavailable(let message):
            missingTargetMessage = message
        default:
            missingTargetMessage = "That bill can't be opened right now."
        }
    }

    private func jump(to date: Date) {
        displayedMonth = DateMath.startOfDay(date)
        selectedDay = DateMath.startOfDay(date)
        reload()
    }

    /// Jumps to the projected debt-free date, preferring the live forecast and
    /// falling back to the store's own baseline. If neither exists there is
    /// nowhere meaningful to jump to, so the view stays where it is rather
    /// than navigating to a date belonging to some other plan.
    private func jumpToDebtFree() {
        let forecast = try? appEnvironment.reforecastService(context: modelContext).latestForecast()
        let baseline = (try? PlanRepository.currentPlan(context: modelContext))??.baselinePayoffDate
        guard let target = forecast?.projectedPayoffDate ?? baseline else { return }
        jump(to: target)
    }

    private func reload() {
        // Load the whole displayed month plus a week of margin on both
        // sides, so week mode near a month edge stays populated.
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return }
        let service = appEnvironment.calendarService(context: modelContext)
        events = (try? service.events(
            from: DateMath.addingDays(-7, to: interval.start),
            to: DateMath.addingDays(6, to: interval.end)
        )) ?? []
    }
}

/// Read-only detail for a ledger entry opened from the calendar.
struct LedgerEntryDetailSheet: View {
    let entry: LedgerEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Entry") {
                    LabeledContent("Type", value: entry.type.displayName)
                    LabeledContent("Amount", value: MoneyFormat.string(entry.amount))
                    LabeledContent("Date", value: DateMath.mediumString(entry.effectiveDate))
                    if let planID = entry.debtPlanID, !planID.isEmpty {
                        LabeledContent("Card", value: planID)
                    }
                    if let note = entry.note, !note.isEmpty {
                        LabeledContent("Note", value: note)
                    }
                }
            }
            .navigationTitle("Ledger entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Milestone detail opened from the calendar, with a route to Progress.
struct MilestoneDetailSheet: View {
    let milestone: Milestone
    let onViewProgress: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Milestone") {
                    LabeledContent("Title", value: milestone.title)
                    if let achieved = milestone.achievedDate {
                        LabeledContent("Achieved", value: DateMath.mediumString(achieved))
                    } else if let forecast = milestone.forecastDate {
                        LabeledContent("Projected", value: DateMath.mediumString(forecast))
                    }
                    if let baseline = milestone.baselineDate {
                        LabeledContent("Original plan", value: DateMath.mediumString(baseline))
                    }
                }
                Section {
                    Button {
                        onViewProgress()
                    } label: {
                        Label("View progress", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
            }
            .navigationTitle("Milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
