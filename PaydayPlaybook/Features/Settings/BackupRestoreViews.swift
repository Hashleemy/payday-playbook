import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Back Up & Restore (V3-09).
///
/// Split into one screen per action rather than one "Backup & export" page,
/// because backing up and replacing everything you own are not the same kind
/// of decision and should not sit two rows apart under one heading.

// MARK: - Create backup

struct CreateBackupView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var backupURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("Saves everything in the app — accounts, bills, debts, plans, check-ins, and history — as one JSON file.")
            }
            Section {
                Label {
                    Text("This file contains your financial information in plain text. Anyone who opens it can read your balances. Keep it somewhere you trust.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Before you share it")
            }
            Section {
                Button {
                    createBackup()
                } label: {
                    Label("Create JSON backup", systemImage: "doc.badge.arrow.up")
                }
                if let backupURL {
                    // The file exists only on this device until this button is
                    // tapped. Nothing is uploaded automatically (V3-09).
                    ShareLink(item: backupURL) {
                        Label("Share \(backupURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                    Text("Created. It stays on this iPhone until you share it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Create JSON Backup")
    }

    private func createBackup() {
        errorMessage = nil
        do {
            backupURL = try BackupPortingService(context: modelContext).exportBackup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Restore backup

struct RestoreBackupView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showImporter = false
    @State private var preview: RestorePreview?
    @State private var details: RestoreDetails?
    @State private var createSafetyBackup = true
    @State private var confirmingReplace = false
    @State private var outcome: RestoreOutcome?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let outcome {
                completedSection(outcome)
            } else if let preview {
                previewSections(preview)
            } else {
                introSection
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Restore JSON Backup")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): stage(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Replace everything in the app with this backup?",
            isPresented: $confirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace all data", role: .destructive) { commit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(createSafetyBackup
                 ? "A safety backup of your current data is saved first."
                 : "No safety backup will be saved. Your current data cannot be recovered.")
        }
    }

    private var introSection: some View {
        Group {
            Section {
                Text("Restoring replaces everything currently in the app with the contents of a backup file.")
                Text("The file is checked and summarized first. Nothing changes until you confirm.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    errorMessage = nil
                    showImporter = true
                } label: {
                    Label("Choose a backup file…", systemImage: "doc.badge.arrow.down")
                }
            }
        }
    }

    @ViewBuilder
    private func previewSections(_ preview: RestorePreview) -> some View {
        Section {
            LabeledContent("Backup date", value: DateMath.mediumString(preview.exportedAt))
            LabeledContent("Format", value: "Version \(preview.schemaVersion)")
            if let appVersion = preview.appVersion {
                LabeledContent("Written by", value: "App \(appVersion)")
            }
            LabeledContent("Records", value: "\(preview.totalRecords)")
        } header: {
            Text("This file")
        }

        Section {
            ForEach(preview.counts) { count in
                LabeledContent(count.label, value: "\(count.count)")
            }
        } header: {
            Text("What it holds")
        } footer: {
            // Counts and categories only — actual amounts stay behind the
            // explicit reveal below (V3-09).
            Text("Amounts and names aren't shown here.")
        }

        if !preview.categories.isEmpty {
            Section("Summary") {
                ForEach(preview.categories, id: \.self) { Text($0) }
            }
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
            if let details {
                detailRows("Accounts", details.accounts)
                detailRows("Debts", details.debts)
                detailRows("Bills", details.obligations)
            } else {
                Button {
                    // Reading real values is a deliberate act, never the
                    // default rendering of a preview.
                    details = preview.revealDetails()
                } label: {
                    Label("Show names and amounts", systemImage: "eye")
                }
            }
        } header: {
            Text("Details")
        }

        Section {
            Toggle("Save a safety backup first", isOn: $createSafetyBackup)
            Button(role: .destructive) {
                confirmingReplace = true
            } label: {
                Label("Replace all data", systemImage: "arrow.triangle.2.circlepath")
            }
            Button("Cancel") { reset() }
        } footer: {
            Text("Cancelling changes nothing — this file hasn't been written yet.")
        }
    }

    @ViewBuilder
    private func detailRows(_ title: String, _ rows: [RestoreDetails.Row]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                LabeledContent(row.label, value: row.value)
            }
        }
    }

    @ViewBuilder
    private func completedSection(_ outcome: RestoreOutcome) -> some View {
        Section {
            Label("Restore complete.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.mint)
            LabeledContent("Records restored", value: "\(outcome.restoredRecords)")
            if let from = outcome.upgradedFromSchema {
                Text("The backup used format \(from) and was upgraded as it was restored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if let safety = outcome.safetyBackupURL {
            Section {
                ShareLink(item: safety) {
                    Label("Share the safety backup", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Your previous data")
            } footer: {
                Text("Saved as \(safety.lastPathComponent). Share it now if you want to keep it.")
            }
        }
    }

    private func stage(_ url: URL) {
        errorMessage = nil
        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            preview = try BackupPortingService(context: modelContext).stage(data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        guard let preview else { return }
        errorMessage = nil
        do {
            outcome = try BackupPortingService(context: modelContext)
                .commit(preview, createSafetyBackup: createSafetyBackup)
            self.preview = nil
            details = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reset() {
        preview = nil
        details = nil
        errorMessage = nil
    }
}

// MARK: - CSV

/// The v0.2.0 CSV exports (F-14), carried forward unchanged. They live beside
/// the JSON backup because they are the same kind of thing — data out — and
/// deliberately not under Reports, which is for the human-readable PDF (V3-11).
struct ExportCSVView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var urls: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("Spreadsheet copies of your ledger, balance history, debts, and check-ins.")
                Text("A CSV can't be restored back into the app — use a JSON backup for that.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    createFiles()
                } label: {
                    Label("Create CSV files", systemImage: "tablecells")
                }
                ForEach(urls, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
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
        .navigationTitle("Export CSV Files")
    }

    private func createFiles() {
        errorMessage = nil
        do {
            urls = try ExportService.exportCSVs(context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
