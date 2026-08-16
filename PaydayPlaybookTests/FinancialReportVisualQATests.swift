import XCTest
import SwiftData
import PDFKit
import UIKit
@testable import PaydayPlaybook

/// Writes representative PDFs to disk so a human (or an agent with an image
/// reader) can look at them, and asserts the layout properties that a
/// screenshot would otherwise be the only way to catch.
///
/// Rendering is checked by the rest of `FinancialReportTests`; this exists
/// because "does it fit on the page" and "is it pleasant to read" are not the
/// same question, and only the second one needs eyes. Set `PP_QA_PDF_DIR` to
/// have the samples written somewhere you can open them; without it the export
/// is skipped and only the assertions run, so CI never depends on a path.
final class FinancialReportVisualQATests: XCTestCase {

    private var exportDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PP_QA_PDF_DIR"], !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, as name: String) {
        guard let directory = exportDirectory else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }

    /// Also emits one PNG per page. Reviewing a PDF means looking at every
    /// page, and the toolchain on a build machine may have no way to rasterize
    /// one — PDFKit is already linked here, so the suite does it itself.
    private func writePageImages(_ document: PDFDocument, named sample: String) {
        guard let directory = exportDirectory else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: bounds.size))
                context.cgContext.translateBy(x: 0, y: bounds.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            guard let data = image.pngData() else { continue }
            let name = String(format: "%@-page-%02d.png", sample, index + 1)
            try? data.write(to: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Samples

    func testRendersRepresentativeSamples() throws {
        for sample in try samples() {
            let data = FinancialReportRenderer.pdfData(for: sample.report)
            let document = try XCTUnwrap(PDFDocument(data: data), "\(sample.name) produced no PDF")

            XCTAssertGreaterThanOrEqual(document.pageCount, sample.minimumPages,
                                        "\(sample.name) rendered fewer pages than expected")
            try assertNoTextOverflowsThePage(document, sample: sample.name)
            try assertEveryPageIsNumbered(document, sample: sample.name)
            write(data, as: "\(sample.name).pdf")
            writePageImages(document, named: sample.name)
        }
    }

    private struct Sample {
        let name: String
        let report: FinancialReport
        var minimumPages: Int = 1
    }

    private func samples() throws -> [Sample] {
        var samples: [Sample] = []

        // 1. A full-detail report over a populated store: the long one, with
        //    the paycheck schedule, charts, and every section.
        let full = ModelContext(try TestSupport.makeContainer())
        let setup = try PortabilityFixtures.setupWithPlan(full)
        try PortabilityFixtures.addHistory(full, setup: setup)
        var fullConfig = ReportConfiguration.standard(from: PortabilityFixtures.today)
        fullConfig.detailLevel = .full
        fullConfig.sections = Set(ReportConfiguration.Section.allCases)
        fullConfig.extraPayment = StoredExtraPayment(
            id: UUID(), kind: .oneTime, amount: TestSupport.money("750.00"),
            effectiveDate: TestSupport.date(2054, 4, 3),
            targetDebtID: setup.debts[0].id, sourceAccountID: nil
        )
        samples.append(Sample(
            name: "01-full-detail",
            report: try service(full).buildReport(fullConfig),
            minimumPages: 3
        ))

        // 2. Summary detail: the short one, with capped tables.
        var summaryConfig = ReportConfiguration.standard(from: PortabilityFixtures.today)
        summaryConfig.detailLevel = .summary
        samples.append(Sample(
            name: "02-summary",
            report: try service(full).buildReport(summaryConfig)
        ))

        // 3. Masked and balance-free: the version a user hands to someone else.
        var maskedConfig = ReportConfiguration.standard(from: PortabilityFixtures.today)
        maskedConfig.privacyOptions = ReportConfiguration.PrivacyOptions(
            maskNames: true, omitBalances: true
        )
        samples.append(Sample(
            name: "03-masked",
            report: try service(full).buildReport(maskedConfig)
        ))

        // 4. Long labels: every table's worst case for wrapping.
        let long = ModelContext(try TestSupport.makeContainer())
        try PortabilityFixtures.modernSetup(long)
        long.insert(PortabilityFixtures.debt(
            planID: "L1",
            name: "Credit union consolidation line of credit opened in the spring",
            balance: "12500.00", apr: "0.1425", minimum: "310.00",
            dueDay: 28, priority: 4, type: .creditCard
        ))
        long.insert(RecurringObligation(
            name: "Household utilities, internet, and streaming bundle",
            amount: TestSupport.money("245.00"), cadence: .monthly, dueDay: 22,
            createdAt: PortabilityFixtures.today, updatedAt: PortabilityFixtures.today
        ))
        try long.save()
        samples.append(Sample(
            name: "04-long-labels",
            report: try service(long).buildReport(ReportConfiguration.standard(from: PortabilityFixtures.today))
        ))

        // 5. Empty store: every section in its "nothing here" state.
        let empty = ModelContext(try TestSupport.makeContainer())
        samples.append(Sample(
            name: "05-empty",
            report: try service(empty).buildReport(ReportConfiguration.standard(from: PortabilityFixtures.today))
        ))

        // 6. Negative and missing states: overdrawn account, protected cash
        //    above the balance, an unstated scenario constraint.
        let negative = ModelContext(try TestSupport.makeContainer())
        let negativeSetup = try PortabilityFixtures.modernSetup(negative, statingScenarioConstraints: false)
        negativeSetup.spending.currentBalance = TestSupport.money("-320.00")
        negativeSetup.reserves.protectedAmount = TestSupport.money("4000.00")
        negativeSetup.spending.balanceAsOf = nil
        try negative.save()
        samples.append(Sample(
            name: "06-negative-and-missing",
            report: try service(negative).buildReport(ReportConfiguration.standard(from: PortabilityFixtures.today))
        ))

        return samples
    }

    private func service(_ context: ModelContext) -> FinancialReportService {
        FinancialReportService(context: context, dateProvider: PortabilityFixtures.dateProvider)
    }

    // MARK: - Layout assertions

    /// Every glyph must sit inside the printable area. Catches the failure a
    /// screenshot shows instantly and a content test never sees: a column that
    /// ran off the right edge, or a block drawn past the footer.
    private func assertNoTextOverflowsThePage(_ document: PDFDocument, sample: String) throws {
        let margin = FinancialReportRenderer.margin
        let printable = CGRect(
            x: margin - 2,
            y: margin - 2,
            width: FinancialReportRenderer.pageSize.width - margin * 2 + 4,
            height: FinancialReportRenderer.pageSize.height - margin * 2 + 4
        )
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            guard let text = page.string, !text.isEmpty else { continue }
            let count = page.numberOfCharacters
            for character in 0..<count {
                let bounds = page.characterBounds(at: character)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                XCTAssertTrue(
                    printable.insetBy(dx: -1, dy: -1).contains(bounds),
                    "\(sample) page \(index + 1): text at \(bounds) falls outside the printable area"
                )
            }
        }
    }

    private func assertEveryPageIsNumbered(_ document: PDFDocument, sample: String) throws {
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let text = page.string ?? ""
            XCTAssertTrue(
                text.contains("Page \(index + 1) of \(document.pageCount)"),
                "\(sample) page \(index + 1) has no page number"
            )
        }
    }
}
