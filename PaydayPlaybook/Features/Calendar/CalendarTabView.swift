import SwiftUI
import SwiftData

/// Month/list calendar with event markers and a selected-day panel (F-07).
struct CalendarTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query private var checkIns: [PaydayCheckIn]
    @Query private var ledgerEntries: [LedgerEntry]

    enum Mode: String, CaseIterable, Identifiable {
        case month = "Month"
        case list = "List"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .month
    @State private var displayedMonth: Date = Date()
    @State private var selectedDay: Date?
    @State private var filter: CalendarEventService.Filter = .all
    @State private var events: [CalendarEventService.Event] = []
    @State private var checkInItem: PaydayPlanItem?
    @State private var showAddSheet = false

    private var calendar: Calendar { DateMath.calendar }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                if mode == .month {
                    monthGrid
                    Divider()
                    selectedDayPanel
                } else {
                    eventList
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
                displayedMonth = DateMath.startOfDay(appEnvironment.dateProvider.now)
                selectedDay = DateMath.startOfDay(appEnvironment.dateProvider.now)
                reload()
            }
            .onChange(of: displayedMonth) { _, _ in reload() }
            .onChange(of: checkIns.count) { _, _ in reload() }
            .onChange(of: ledgerEntries.count) { _, _ in reload() }
            .sheet(item: $checkInItem, onDismiss: reload) { item in
                CheckInFlowView(planItem: item)
            }
            .sheet(isPresented: $showAddSheet, onDismiss: reload) {
                QuickAddSheet()
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

    private func dayCell(_ day: Date) -> some View {
        let dayEvents = eventsByDay[day] ?? []
        let isSelected = selectedDay.map { DateMath.isSameDay($0, day) } ?? false
        let isToday = DateMath.isSameDay(day, appEnvironment.dateProvider.now)
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                HStack(spacing: 2) {
                    ForEach(Array(Set(dayEvents.map(\.kind))).sorted { $0.rawValue < $1.rawValue }.prefix(3), id: \.self) { kind in
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(day, events: dayEvents))
    }

    private func markerColor(_ kind: CalendarEventService.EventKind) -> Color {
        switch kind {
        case .paydayFuture: return .blue
        case .paydayCompleted: return .mint
        case .paydayDue: return .orange
        case .cardDue: return Color(red: 0.94, green: 0.45, blue: 0.40)
        case .milestone: return .mint
        case .entry: return .gray
        }
    }

    private func dayAccessibilityLabel(_ day: Date, events: [CalendarEventService.Event]) -> String {
        var label = DateMath.mediumString(day)
        if events.isEmpty {
            label += ", no events"
        } else {
            label += ", " + events.map { "\($0.kind.label): \($0.title)" }.joined(separator: ", ")
        }
        return label
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
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

    private var filteredEvents: [CalendarEventService.Event] {
        events.filter { filter.includes($0.kind) }
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

    private var eventList: some View {
        List {
            ForEach(filteredEvents) { event in
                eventRow(event, showDate: true)
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
    private func eventRow(_ event: CalendarEventService.Event, showDate: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.symbolName)
                .foregroundStyle(markerColor(event.kind))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(event.kind.label)
                    if showDate {
                        Text("· \(DateMath.mediumString(event.date))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if actionLabel(event) != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { performAction(event) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(actionLabel(event) != nil ? .isButton : [])
        .accessibilityHint(actionLabel(event) ?? "")
    }

    private func actionLabel(_ event: CalendarEventService.Event) -> String? {
        switch event.kind {
        case .paydayFuture, .paydayCompleted, .paydayDue: return "Open check-in"
        case .cardDue: return "Open card"
        case .milestone: return "View milestone"
        case .entry: return nil
        }
    }

    private func performAction(_ event: CalendarEventService.Event) {
        switch event.kind {
        case .paydayFuture, .paydayCompleted, .paydayDue:
            guard let reference = event.reference, let itemID = UUID(uuidString: reference) else { return }
            let items = (try? modelContext.fetch(FetchDescriptor<PaydayPlanItem>())) ?? []
            checkInItem = items.first { $0.id == itemID }
        case .cardDue:
            router.pendingDebtPlanID = event.reference
            router.selectedTab = .debts
        case .milestone:
            router.selectedTab = .progress
        case .entry:
            break
        }
    }

    // MARK: - Actions

    private func shiftMonth(_ direction: Int) {
        if let next = calendar.date(byAdding: .month, value: direction, to: displayedMonth) {
            displayedMonth = next
        }
    }

    private func jump(to date: Date) {
        displayedMonth = DateMath.startOfDay(date)
        selectedDay = DateMath.startOfDay(date)
        reload()
    }

    private func jumpToDebtFree() {
        let forecast = try? appEnvironment.reforecastService(context: modelContext).latestForecast()
        let target = forecast?.projectedPayoffDate ?? PlanContract.baselinePayoffDate
        jump(to: target)
    }

    private func reload() {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return }
        let service = appEnvironment.calendarService(context: modelContext)
        events = (try? service.events(
            from: interval.start,
            to: DateMath.addingDays(-1, to: interval.end)
        )) ?? []
    }
}
