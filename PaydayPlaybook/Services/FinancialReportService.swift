import Foundation
import SwiftData

/// Generate Financial Report (V3-11), implementing `ReportGenerating`.
///
/// The distinction this service exists to enforce: **a report is a document,
/// not an export.** A JSON backup protects data; a report explains it. They
/// live in different Settings groups, produce different file types, and are
/// never presented as substitutes for one another.
///
/// File lifecycle (A-11): the PDF is written into the app's own temporary
/// reports directory, never uploaded, and handed out only through the share
/// sheet the user taps. It is deleted when the report screen closes and again
/// on the next cold launch — see `PortableFileStore`.
protocol ReportGenerating {
    func generate(_ config: ReportConfiguration) throws -> URL
}

struct FinancialReportService: ReportGenerating {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    /// Builds the content model. Exposed so tests (and previews) can assert
    /// what a report *says* without rendering a PDF.
    func buildReport(_ config: ReportConfiguration) throws -> FinancialReport {
        try FinancialReportBuilder(context: context, dateProvider: dateProvider).build(config)
    }

    func pdfData(_ config: ReportConfiguration) throws -> Data {
        FinancialReportRenderer.pdfData(for: try buildReport(config))
    }

    func generate(_ config: ReportConfiguration) throws -> URL {
        let data = try pdfData(config)
        return try PortableFileStore.write(
            data,
            named: "PaydayPlaybook-Report-\(PortableFileStore.timestamp(dateProvider.now)).pdf",
            in: .reports
        )
    }

    /// Called when the report screen closes. Generating a report is cheap;
    /// leaving a plaintext PDF of someone's finances in temporary storage
    /// after they have walked away from the screen is not.
    static func discardGeneratedReports() {
        PortableFileStore.purge(.reports)
    }
}
