import SwiftUI
import SwiftData

/// Settings → Export Template / Import Template (V3-10).
///
/// The export screen's job is consent: it starts with nothing sensitive
/// selected, and every switch the user flips states in full what turning it on
/// will put in a file they may hand to somebody else.

// MARK: - Export

struct ExportTemplateView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var includedCategories: Set<TemplateSensitiveCategory> = []
    @State private var templateURL: URL?
    @State private var confirmingExport = false
    @State private var errorMessage: String?

    private var options: TemplateExportOptions {
        TemplateExportOptions(includedCategories: includedCategories)
    }

    var body: some View {
        List {
            Section {
                Text("A template is your setup without your money: which accounts you keep, what kinds of bills and debts you have, how often you're paid, and how your reminders are set.")
            }

            Section {
                ForEach(TemplateStructuralExclusion.allCases, id: \.self) { exclusion in
                    Label(exclusion.rawValue, systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Never included")
            } footer: {
                Text("These have no place in the template format at all, whatever you choose below.")
            }

            Section {
                ForEach(TemplateSensitiveCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Without this the switch announces as its title *and* its
                    // whole explanation run together. The name is the label;
                    // what including it means is the hint.
                    .accessibilityLabel(category.title)
                    .accessibilityHint(category.warning)
                }
            } header: {
                Text("Include real values")
            } footer: {
                Text(includedCategories.isEmpty
                     ? "Nothing here is included by default."
                     : "Turned on: \(includedCategories.map(\.title).sorted().joined(separator: ", ")).")
            }

            Section {
                Button {
                    if includedCategories.isEmpty { export() } else { confirmingExport = true }
                } label: {
                    Label("Export template", systemImage: "square.and.arrow.up.on.square")
                }
                if let templateURL {
                    ShareLink(item: templateURL) {
                        Label("Share \(templateURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Export Template")
        .confirmationDialog(
            "This template will contain real values",
            isPresented: $confirmingExport,
            titleVisibility: .visible
        ) {
            Button("Export anyway", role: .destructive) { export() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(options.warnings.joined(separator: "\n\n"))
        }
    }

    private func binding(for category: TemplateSensitiveCategory) -> Binding<Bool> {
        Binding(
            get: { includedCategories.contains(category) },
            set: { isOn in
                if isOn { includedCategories.insert(category) } else { includedCategories.remove(category) }
                // A changed selection means the written file no longer matches
                // what the buttons say.
                templateURL = nil
            }
        )
    }

    private func export() {
        errorMessage = nil
        do {
            templateURL = try TemplateImportExportService(context: modelContext)
                .exportTemplate(options: options)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Import

struct ImportTemplateView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showImporter = false
    @State private var preview: TemplatePreview?
    @State private var mode: TemplateApplyMode = .merge
    @State private var outcome: TemplateApplyOutcome?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let outcome {
                outcomeSections(outcome)
            } else if let preview {
                previewSections(preview)
            } else {
                Section {
                    Text("Applying a template adds setup you don't have yet. It never changes your recorded history, balances, or plans.")
                }
                Section {
                    Button {
                        errorMessage = nil
                        showImporter = true
                    } label: {
                        Label("Choose a template file…", systemImage: "doc.badge.plus")
                    }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Import Template")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): loadPreview(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func previewSections(_ preview: TemplatePreview) -> some View {
        Section {
            if let exportedAt = preview.exportedAt {
                LabeledContent("Created", value: DateMath.mediumString(exportedAt))
            }
            LabeledContent("Format", value: "Version \(preview.schemaVersion)")
            ForEach(preview.counts) { count in
                LabeledContent(count.label, value: "\(count.count)")
            }
        } header: {
            Text("This template")
        }

        if !preview.categories.isEmpty {
            Section("What's in it") {
                ForEach(preview.categories, id: \.self) { Text($0) }
            }
        }

        Section {
            if preview.includedCategories.isEmpty {
                Label("Structure only — no names or amounts", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(preview.includedCategories) { category in
                    Label(category.title, systemImage: "eye")
                }
            }
        } header: {
            Text("Real values it carries")
        }

        if !preview.warnings.isEmpty {
            Section("Worth knowing") {
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
        }

        Section {
            Picker("How to apply", selection: $mode) {
                ForEach(TemplateApplyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Text(mode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Apply")
        }

        Section {
            Button {
                apply(preview)
            } label: {
                Label("Apply template", systemImage: "square.and.arrow.down")
            }
            Button("Cancel") { reset() }
        } footer: {
            Text("Your recorded history, balances, and plans are never changed by this.")
        }
    }

    @ViewBuilder
    private func outcomeSections(_ outcome: TemplateApplyOutcome) -> some View {
        Section {
            Label("Template applied.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.mint)
            if outcome.accountsAdded > 0 { LabeledContent("Accounts added", value: "\(outcome.accountsAdded)") }
            if outcome.billsAdded > 0 { LabeledContent("Bills added", value: "\(outcome.billsAdded)") }
            if outcome.debtsAdded > 0 { LabeledContent("Debts added", value: "\(outcome.debtsAdded)") }
            if outcome.remindersAdded > 0 { LabeledContent("Reminders added", value: "\(outcome.remindersAdded)") }
            if outcome.incomeApplied { Label("Pay schedule added", systemImage: "calendar") }
        }
        if !outcome.needsValues.isEmpty {
            Section {
                ForEach(outcome.needsValues, id: \.self) { item in
                    Label(item, systemImage: "pencil.circle")
                }
            } header: {
                Text("Needs an amount from you")
            } footer: {
                Text("These weren't added because the template didn't include an amount, and the app won't invent one.")
            }
        }
        if !outcome.skipped.isEmpty {
            Section("Already set up") {
                ForEach(outcome.skipped, id: \.self) { item in
                    Label(item, systemImage: "equal.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadPreview(_ url: URL) {
        errorMessage = nil
        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            preview = try TemplateImportExportService(context: modelContext).preview(data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ preview: TemplatePreview) {
        errorMessage = nil
        do {
            outcome = try TemplateImportExportService(context: modelContext).apply(preview, mode: mode)
            self.preview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reset() {
        preview = nil
        errorMessage = nil
    }
}
