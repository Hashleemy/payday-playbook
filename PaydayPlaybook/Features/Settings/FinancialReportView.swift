import SwiftUI
import SwiftData

/// Settings → Reports → Generate Financial Report (V3-11).
///
/// Deliberately its own group, and deliberately not next to the JSON backup:
/// a report is something you read, a backup is something you keep. Raw JSON is
/// never labeled a report.
struct FinancialReportView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var rangeChoice: RangeChoice = .ninetyDays
    @State private var detailLevel: ReportConfiguration.DetailLevel = .standard
    @State private var sections: Set<ReportConfiguration.Section> = ReportConfiguration.Section.defaults
    @State private var includeAppendix = true
    @State private var includeArchived = false
    @State private var maskNames = false
    @State private var omitBalances = false

    @State private var reportURL: URL?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    enum RangeChoice: String, CaseIterable, Identifiable {
        case thirtyDays, sixtyDays, ninetyDays, sixMonths, year
        var id: String { rawValue }

        var title: String {
            switch self {
            case .thirtyDays: return "Next 30 days"
            case .sixtyDays: return "Next 60 days"
            case .ninetyDays: return "Next 90 days"
            case .sixMonths: return "Next 6 months"
            case .year: return "Next 12 months"
            }
        }

        var days: Int {
            switch self {
            case .thirtyDays: return 30
            case .sixtyDays: return 60
            case .ninetyDays: return 90
            case .sixMonths: return 182
            case .year: return 365
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text("A readable PDF of your current setup and what the plan projects — the kind of thing you'd print or hand to someone.")
            }

            Section("Date range") {
                Picker("Range", selection: $rangeChoice) {
                    ForEach(RangeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Picker("Detail", selection: $detailLevel) {
                    ForEach(ReportConfiguration.DetailLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(detailDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Include appendix", isOn: $includeAppendix)
                Toggle("Include archived accounts and debts", isOn: $includeArchived)
            } header: {
                Text("Detail")
            }

            Section {
                ForEach(ReportConfiguration.Section.allCases) { section in
                    Toggle(section.title, isOn: sectionBinding(section))
                }
            } header: {
                Text("Sections")
            } footer: {
                Text("Extra payment is off unless you're modeling one.")
            }

            Section {
                Toggle("Replace names with generic labels", isOn: $maskNames)
                Toggle("Leave out balances", isOn: $omitBalances)
            } header: {
                Text("If you're sharing it")
            } footer: {
                Text("Both options apply to the whole report, including the notes and warnings.")
            }

            Section {
                Button {
                    generate()
                } label: {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Label("Generate Financial Report", systemImage: "doc.richtext")
                    }
                }
                .disabled(isGenerating || sections.isEmpty)

                if let reportURL {
                    // The PDF exists only on this device until this is tapped.
                    ShareLink(item: reportURL) {
                        Label("Share \(reportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                if reportURL != nil {
                    Text("The report stays on this iPhone. It's deleted when you leave this screen, so share it now if you want to keep it.")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Generate Financial Report")
        .onDisappear {
            // A-11: the file's lifetime is bounded by the screen that made it.
            // Anything the user wanted to keep left through the share sheet,
            // which copies rather than references.
            FinancialReportService.discardGeneratedReports()
        }
    }

    private var detailDescription: String {
        switch detailLevel {
        case .summary: return "Headline figures, with long tables shortened."
        case .standard: return "Full tables, without the paycheck-by-paycheck schedule."
        case .full: return "Everything, including every paycheck in range."
        }
    }

    private func sectionBinding(_ section: ReportConfiguration.Section) -> Binding<Bool> {
        Binding(
            get: { sections.contains(section) },
            set: { isOn in
                if isOn { sections.insert(section) } else { sections.remove(section) }
                reportURL = nil
            }
        )
    }

    private func generate() {
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }

        var config = ReportConfiguration.standard(from: Date(), days: rangeChoice.days)
        config.sections = sections
        config.detailLevel = detailLevel
        config.includeAppendix = includeAppendix
        config.entityScope = ReportConfiguration.EntityScope(includeArchived: includeArchived)
        config.privacyOptions = ReportConfiguration.PrivacyOptions(
            maskNames: maskNames, omitBalances: omitBalances
        )

        do {
            reportURL = try FinancialReportService(context: modelContext).generate(config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
