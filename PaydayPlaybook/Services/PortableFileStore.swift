import Foundation

/// Where generated files live before the user decides to share them, and when
/// they stop existing (A-11, V3-09/V3-11).
///
/// Every file this app generates — JSON backups, templates, CSVs, PDF reports —
/// contains the user's finances in the clear. The rule is therefore: generated
/// files stay inside the app's own temporary container, are handed to the
/// system share sheet only when the user taps share, and are deleted on the
/// next cold launch and whenever the screen that produced them closes.
///
/// `.temporaryDirectory` rather than Documents: files there are not exposed to
/// the Files app, are excluded from backup, and iOS may reclaim them on its
/// own — every one of which is the behavior we want for a share-and-forget
/// artifact. The v0.2.0 restore path wrote its rollback backup into the
/// *Documents* directory, where it stayed forever; `safety` corrects that
/// while keeping the file long enough to be useful (see `purgeTransient`).
enum PortableFileStore {

    enum Category: String, CaseIterable {
        case backups = "Backups"
        case templates = "Templates"
        case reports = "Reports"
        case csv = "CSV"
        /// Automatic pre-restore backups. Kept across launches — a safety net
        /// that evaporates on relaunch is not a safety net — and pruned by age
        /// and count instead.
        case safety = "Safety"

        /// Whether `purgeTransient()` clears this category wholesale.
        var isTransient: Bool { self != .safety }
    }

    /// Root of the app's generated-file area.
    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PaydayPlaybook", isDirectory: true)
    }

    @discardableResult
    static func directory(_ category: Category) -> URL {
        let url = root().appendingPathComponent(category.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func backupsDirectory() -> URL { directory(.backups) }
    static func templatesDirectory() -> URL { directory(.templates) }
    static func reportsDirectory() -> URL { directory(.reports) }
    static func csvDirectory() -> URL { directory(.csv) }
    static func safetyDirectory() -> URL { directory(.safety) }

    /// Deletes everything in one category. Called when the screen that
    /// produced the files closes, so a shared file's lifetime is bounded by
    /// the flow that made it rather than by the process.
    static func purge(_ category: Category) {
        let url = directory(category)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return }
        for file in contents {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Cold-launch cleanup: clears every transient category and prunes safety
    /// backups. Anything the user wanted to keep left the container through
    /// the share sheet, which copies rather than references.
    static func purgeTransient(now: Date = Date()) {
        for category in Category.allCases where category.isTransient {
            purge(category)
        }
        pruneSafetyBackups(now: now)
    }

    /// Safety backups kept: the newest `safetyBackupKeepCount`, and nothing
    /// older than `safetyBackupMaxAge` regardless of count. Bounded both ways
    /// so a user who restores repeatedly does not accumulate copies of their
    /// entire financial history in temporary storage.
    static let safetyBackupKeepCount = 3
    static let safetyBackupMaxAge: TimeInterval = 14 * 24 * 60 * 60

    /// `now` defaults to the wall clock and callers should leave it there.
    ///
    /// File modification times come from the filesystem, which knows only the
    /// real clock — comparing them against an injected test date measures the
    /// gap between two different clocks and deletes everything. The injected
    /// provider governs dates the *user* sees (file names, report headers),
    /// not filesystem housekeeping.
    static func pruneSafetyBackups(now: Date = Date()) {
        let url = directory(.safety)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let dated = contents.map { file -> (URL, Date) in
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (file, modified)
        }.sorted { $0.1 > $1.1 }

        for (index, entry) in dated.enumerated() {
            let tooMany = index >= safetyBackupKeepCount
            let tooOld = now.timeIntervalSince(entry.1) > safetyBackupMaxAge
            if tooMany || tooOld {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }

    /// Files currently held in a category, newest first. Drives the "recent
    /// safety backups" list so a user can find the file a failed restore left
    /// behind without leaving the app.
    static func files(in category: Category) -> [URL] {
        let url = directory(category)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return contents.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }
    }

    /// Writes generated data with file protection on. `.completeFileProtection`
    /// means the file is unreadable while the device is locked, which matters
    /// for a plaintext copy of someone's balances sitting in temp storage.
    static func write(_ data: Data, named name: String, in category: Category) throws -> URL {
        let url = directory(category).appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw PortabilityError.writeFailed
        }
        return url
    }

    /// `yyyyMMdd-HHmmss` stamp used in every generated file name. Local time,
    /// because the user recognizes their own clock; the document's own
    /// `exportedAt` carries the unambiguous instant.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
