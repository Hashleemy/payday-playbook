import Foundation

/// Versioned envelope shared by every JSON document the app writes or reads
/// (V3-09/V3-10, MVP_LAYOUT §6 "Portability layer").
///
/// The envelope exists so a reader can answer three questions *before* it
/// trusts a single byte of payload: what kind of document is this, what schema
/// does it speak, and does the payload still contain what the writer said it
/// contained. v0.2.0 had none of that — a backup was a bare `Backup` object,
/// so a template and a backup were indistinguishable until decoding failed
/// somewhere deep inside.
///
/// Nothing in this file executes, evaluates, or dynamically dispatches on
/// imported content. Every read is `Decodable` into a fixed typed shape;
/// unknown keys are ignored, never interpreted (V3-13).

// MARK: - Kind

enum PortableDocumentKind: String, Codable, CaseIterable, Sendable {
    /// Everything needed to reconstruct the store (V3-09).
    case fullBackup
    /// Allow-listed setup structure only (V3-10).
    case template

    var displayName: String {
        switch self {
        case .fullBackup: return "full backup"
        case .template: return "template"
        }
    }
}

// MARK: - Limits (A-10)

/// Hard ceilings applied before and after decode. They exist to bound the work
/// a hostile or corrupt file can make the app do, not because a real user's
/// data approaches them: a decade of biweekly check-ins is a few thousand rows
/// and well under a megabyte. Tunable per A-10.
enum PortableDocumentLimits {
    static let maxFileBytes = 50 * 1_024 * 1_024
    static let maxRecords = 250_000
}

// MARK: - Integrity

/// Per-collection record counts written by the exporter and re-derived by the
/// importer. A mismatch means the file was truncated or edited after export;
/// the counts themselves are structural (how many rows), never financial.
struct PortableIntegrity: Codable, Equatable, Sendable {
    var recordCounts: [String: Int]

    var totalRecords: Int { recordCounts.values.reduce(0, +) }

    init(recordCounts: [String: Int] = [:]) {
        self.recordCounts = recordCounts
    }

    /// Collections whose declared count disagrees with what the payload holds,
    /// as `(collection, declared, found)`. Collections absent from the
    /// declaration are not checked — a document written by an older writer
    /// simply declares fewer of them.
    func disagreements(with derived: PortableIntegrity) -> [(String, Int, Int)] {
        recordCounts.keys.sorted().compactMap { key in
            let declared = recordCounts[key] ?? 0
            let found = derived.recordCounts[key] ?? 0
            return declared == found ? nil : (key, declared, found)
        }
    }
}

// MARK: - Envelope

/// The document as written. `Payload` is `ExportService.Backup` for a full
/// backup and `TemplatePayload` for a template — the envelope fields are
/// identical either way, which is what lets one probe classify both.
struct PortableDocument<Payload: Codable>: Codable {
    var documentKind: PortableDocumentKind
    /// Export schema of the *payload*. Kept equal to the payload's own stamp
    /// where the payload carries one, and validated on read.
    var schemaVersion: Int
    /// Marketing version of the app that wrote the file. Informational: shown
    /// in the preview, never used to gate compatibility (schemaVersion does
    /// that), because a build number tells a reader nothing about shape.
    var appVersion: String
    /// Calculation version in force when the file was written, so a restored
    /// plan can be read back with the rules it was generated under.
    var calculationVersion: Int
    var exportedAt: Date
    var integrity: PortableIntegrity
    var payload: Payload
}

// MARK: - Probe

/// The minimum a reader needs to route a file: its kind and its schema.
///
/// Decoded first, on its own, so an unknown `documentKind` string or an
/// unreadable schema produces a named error instead of a decoder failure
/// pointing at some field three levels down. `documentKind` is read as a
/// `String` rather than the enum for exactly that reason.
struct PortableDocumentProbe {
    /// Nil for export schema 1 and 2, which predate the envelope and are bare
    /// `Backup` objects. Absence therefore *means* "legacy full backup".
    var documentKind: PortableDocumentKind?
    var schemaVersion: Int
    var appVersion: String?
    var exportedAt: Date?

    private struct Raw: Decodable {
        var documentKind: String?
        var schemaVersion: Int?
        var appVersion: String?
        var exportedAt: Date?
    }

    /// Classifies a candidate file. Throws before any payload work so an
    /// oversize or non-JSON file never reaches the decoder.
    static func probe(_ data: Data, decoder: JSONDecoder = PortableCoding.decoder()) throws -> PortableDocumentProbe {
        guard data.count <= PortableDocumentLimits.maxFileBytes else {
            throw PortabilityError.fileTooLarge(bytes: data.count, limit: PortableDocumentLimits.maxFileBytes)
        }
        let raw: Raw
        do {
            raw = try decoder.decode(Raw.self, from: data)
        } catch {
            throw PortabilityError.notJSON
        }
        guard let schemaVersion = raw.schemaVersion else {
            throw PortabilityError.malformed("schemaVersion")
        }
        var kind: PortableDocumentKind?
        if let rawKind = raw.documentKind {
            guard let parsed = PortableDocumentKind(rawValue: rawKind) else {
                throw PortabilityError.unknownDocumentKind(rawKind)
            }
            kind = parsed
        }
        return PortableDocumentProbe(
            documentKind: kind,
            schemaVersion: schemaVersion,
            appVersion: raw.appVersion,
            exportedAt: raw.exportedAt
        )
    }

    /// The kind a reader should treat this file as: an envelope-less document
    /// is a legacy full backup, which is the only thing v0.2.0 could write.
    var effectiveKind: PortableDocumentKind { documentKind ?? .fullBackup }
}

// MARK: - Coding

enum PortableCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys keep exports byte-stable so a round-trip test can compare
        // documents directly rather than re-decoding them.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - Errors

/// Import and export failures.
///
/// Every message names a *structure* — a collection, a field, a count — and
/// never a value. An error string is user-visible and lands in screenshots and
/// bug reports, so "the backup contains an invalid amount: 4183.62" is a
/// financial-data leak dressed as diagnostics (V3-13). The replacement names
/// the collection and field instead, which is what a user needs to find the
/// bad row anyway.
enum PortabilityError: LocalizedError, Equatable {
    case fileTooLarge(bytes: Int, limit: Int)
    case tooManyRecords(count: Int, limit: Int)
    case notJSON
    /// A required field was absent or the wrong type. The associated value is
    /// a field path, never its contents.
    case malformed(String)
    case unknownDocumentKind(String)
    case wrongDocumentKind(expected: PortableDocumentKind, found: PortableDocumentKind)
    case unsupportedSchema(found: Int, lowest: Int, highest: Int)
    case schemaVersionMismatch(envelope: Int, payload: Int)
    case integrityMismatch(collection: String, declared: Int, found: Int)
    case duplicateIdentifiers(collection: String, count: Int)
    case danglingReferences(collection: String, field: String, count: Int)
    /// A money string could not be parsed. Names where, not what.
    case amountUnreadable(collection: String, field: String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            return "This file is \(Self.megabytes(bytes)) MB. The largest file this app will read is \(Self.megabytes(limit)) MB."
        case .tooManyRecords(let count, let limit):
            return "This file holds \(count) records, past the \(limit)-record limit."
        case .notJSON:
            return "This file isn't a Payday Playbook JSON document."
        case .malformed(let field):
            return "This file is missing or has the wrong type for \"\(field)\"."
        case .unknownDocumentKind(let raw):
            return "This file says it is a \"\(raw)\" document, which this app version doesn't recognize."
        case .wrongDocumentKind(let expected, let found):
            return "This is a \(found.displayName) file. Choose it under \(Self.destination(for: found)) instead — this action needs a \(expected.displayName)."
        case .unsupportedSchema(let found, let lowest, let highest):
            if found > highest {
                return "This file was written by a newer version of Payday Playbook (format \(found)). Update the app, then try again."
            }
            return "This file uses format \(found). This app reads formats \(lowest) through \(highest)."
        case .schemaVersionMismatch(let envelope, let payload):
            return "This file's header claims format \(envelope) but its contents are format \(payload). It was edited after export."
        case .integrityMismatch(let collection, let declared, let found):
            return "This file says it holds \(declared) \(collection) records but contains \(found). It is incomplete or was edited after export."
        case .duplicateIdentifiers(let collection, let count):
            return "This file reuses \(count) identifier(s) in \(collection). Records must be unique — importing it would silently merge them."
        case .danglingReferences(let collection, let field, let count):
            return "\(count) \(collection) record(s) point at a \"\(field)\" that isn't in this file."
        case .amountUnreadable(let collection, let field):
            return "An amount in \(collection).\(field) isn't a readable number."
        case .writeFailed:
            return "The file could not be written."
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private static func destination(for kind: PortableDocumentKind) -> String {
        switch kind {
        case .fullBackup: return "Restore JSON Backup"
        case .template: return "Import Template"
        }
    }
}
