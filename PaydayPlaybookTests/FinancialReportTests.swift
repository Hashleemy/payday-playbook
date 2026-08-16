import XCTest
import SwiftData
import PDFKit
@testable import PaydayPlaybook

/// T-14 (V3-11): the report says the right thing, fits on the page, and
/// leaves no file behind.
final class FinancialReportTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeContainer())
    }

    private func service(_ context: ModelContext) -> FinancialReportService {
        FinancialReportService(context: context, dateProvider: PortabilityFixtures.dateProvider)
    }

    private var standardConfig: ReportConfiguration {
        ReportConfiguration.standard(from: PortabilityFixtures.today)
    }

    // MARK: - Content

    func testStandardReportContainsEveryContractedSection() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(context)
        try PortabilityFixtures.addHistory(context, setup: setup)

        let report = try service(context).buildReport(standardConfig)
        let ids = report.sections.map(\.id)

        // MVP_LAYOUT §8.9's required content, section by section.
        for section in ReportConfiguration.Section.defaults {
            XCTAssertTrue(ids.contains(section.rawValue), "missing section \(section.rawValue)")
        }
        XCTAssertTrue(ids.contains("appendix"))
        XCTAssertFalse(report.disclaimer.isEmpty, "an estimate without its disclaimer is a claim")
        XCTAssertTrue(report.disclaimer.contains { $0.contains("financial advice") })
        XCTAssertTrue(report.subtitle.contains("Standard"))
    }

    func testReportUsesTheSameNumbersTheEngineProduces() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        let report = try service(context).buildReport(standardConfig)
        let snapshot = try PlanningInputBuilder(context: context).build(asOf: PortabilityFixtures.today)
        let engine = try PlanGenerationService.generate(from: snapshot).result

        let payoff = try XCTUnwrap(report.sections.first { $0.id == "payoffProjection" })
        let values = payoff.blocks.compactMap { block -> [ReportKeyValue]? in
            if case .keyValues(let kv) = block { return kv }
            return nil
        }.flatMap { $0 }

        let interest = try XCTUnwrap(values.first { $0.label == "Estimated interest" })
        XCTAssertEqual(interest.value, MoneyFormat.string(engine.estimatedTotalInterest),
                       "the report must print the engine's number, not its own")
        let paychecks = try XCTUnwrap(values.first { $0.label == "Paychecks modeled" })
        XCTAssertEqual(paychecks.value, "\(engine.paycheckCount)")
    }

    func testScenarioSectionComparesThreePlansAndEmitsOneChartPerMeasure() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        let report = try service(context).buildReport(standardConfig)
        let section = try XCTUnwrap(report.sections.first { $0.id == "scenarioComparison" })

        let tables = section.blocks.compactMap { block -> ReportTable? in
            if case .table(let table) = block { return table }
            return nil
        }
        let comparison = try XCTUnwrap(tables.first)
        XCTAssertEqual(comparison.rows.count, 3, "exactly three scenarios (R-17)")
        XCTAssertTrue(comparison.rows.contains { $0[0].text.contains("recommended") })

        let charts = section.blocks.compactMap { block -> ReportMagnitudeChart? in
            if case .chart(let chart) = block { return chart }
            return nil
        }
        // One measure per chart: dollars and months never share an axis.
        XCTAssertEqual(charts.count, 2)
        XCTAssertTrue(charts.contains { $0.title.contains("interest") })
        XCTAssertTrue(charts.contains { $0.title.contains("Months") })
        XCTAssertTrue(charts.allSatisfy { $0.bars.allSatisfy { !$0.displayValue.isEmpty } },
                      "every bar is directly labeled, so the chart needs no axis ticks")
    }

    func testMissingScenarioInputsAreNamedRatherThanGuessed() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context, statingScenarioConstraints: false)

        let report = try service(context).buildReport(standardConfig)
        let section = try XCTUnwrap(report.sections.first { $0.id == "scenarioComparison" })
        let callouts = section.blocks.compactMap { block -> ReportCallout? in
            if case .callout(let callout) = block { return callout }
            return nil
        }
        XCTAssertFalse(callouts.isEmpty, "an uncomputable scenario must say what it needs")
        XCTAssertTrue(callouts.contains { $0.title.contains("needs more information") })
        XCTAssertTrue(callouts.allSatisfy { $0.tone == .caution })
    }

    // MARK: - Empty and negative states

    func testEmptyStoreProducesAReportThatSaysSoRatherThanCrashing() throws {
        let context = try makeContext()
        let report = try service(context).buildReport(standardConfig)

        XCTAssertFalse(report.sections.isEmpty)
        let empties = report.sections.flatMap(\.blocks).compactMap { block -> String? in
            if case .empty(let text) = block { return text }
            return nil
        }
        XCTAssertFalse(empties.isEmpty, "sections with no data must say so, not vanish")
        XCTAssertTrue(empties.contains { $0.contains("No checking accounts") })
        XCTAssertTrue(empties.contains { $0.contains("No debts") })

        // And it still renders.
        let data = FinancialReportRenderer.pdfData(for: report)
        XCTAssertGreaterThan(try pageCount(data), 0)
    }

    func testNegativeAvailableCashIsFlaggedNotHidden() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        // Protected more than the balance: available goes negative.
        setup.spending.protectedAmount = TestSupport.money("9000.00")
        try context.save()

        let report = try service(context).buildReport(standardConfig)
        let section = try XCTUnwrap(report.sections.first { $0.id == "accounts" })

        let table = try XCTUnwrap(section.blocks.compactMap { block -> ReportTable? in
            if case .table(let table) = block { return table }
            return nil
        }.first)
        XCTAssertTrue(table.rows.contains { row in row.contains { $0.emphasis == .attention } })

        let callouts = section.blocks.compactMap { block -> ReportCallout? in
            if case .callout(let callout) = block { return callout }
            return nil
        }
        XCTAssertTrue(callouts.contains { $0.title.contains("negative") })
    }

    // MARK: - Configuration

    func testSectionSelectionIsRespected() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        var config = standardConfig
        config.sections = [.accounts, .billsAndDebts]
        config.includeAppendix = false

        let report = try service(context).buildReport(config)
        XCTAssertEqual(report.sections.map(\.id), ["accounts", "billsAndDebts"])
    }

    func testSummaryDetailCapsLongTablesAndSaysSo() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        for index in 0..<8 {
            context.insert(PortabilityFixtures.debt(
                planID: "E\(index)", name: "Extra card \(index)", balance: "100.00",
                apr: "0.10", minimum: "10.00", dueDay: 10, priority: 20 + index, type: .creditCard
            ))
        }
        try context.save()
        _ = setup

        var config = standardConfig
        config.detailLevel = .summary
        let report = try service(context).buildReport(config)
        let section = try XCTUnwrap(report.sections.first { $0.id == "billsAndDebts" })
        let debtTable = try XCTUnwrap(section.blocks.compactMap { block -> ReportTable? in
            if case .table(let table) = block { return table }
            return nil
        }.last)

        XCTAssertEqual(debtTable.rows.count, 5)
        XCTAssertNotNil(debtTable.truncationNote, "a capped table must not read as complete")
    }

    func testEntityScopeLimitsWhichRecordsArePrinted() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)

        var config = standardConfig
        config.entityScope = ReportConfiguration.EntityScope(debtIDs: [setup.debts[0].id])
        let report = try service(context).buildReport(config)
        let section = try XCTUnwrap(report.sections.first { $0.id == "billsAndDebts" })
        let debtTable = try XCTUnwrap(section.blocks.compactMap { block -> ReportTable? in
            if case .table(let table) = block { return table }
            return nil
        }.last)
        XCTAssertEqual(debtTable.rows.count, 1)
        XCTAssertEqual(debtTable.rows[0][0].text, "Blue card")
    }

    func testPrivacyOptionsMaskNamesAndOmitBalances() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        var config = standardConfig
        config.privacyOptions = ReportConfiguration.PrivacyOptions(maskNames: true, omitBalances: true)
        let report = try service(context).buildReport(config)

        let text = renderedText(of: report)
        for label in ["Blue card", "Green card", "Auto loan", "Everyday checking"] {
            XCTAssertFalse(text.contains(label), "masked report leaked \(label)")
        }
        for amount in ["2,400", "3,200", "1,450", "6,800"] {
            XCTAssertFalse(text.contains(amount), "balance-free report leaked \(amount)")
        }
        XCTAssertTrue(text.contains("Debt 1"))
    }

    func testDateRangeClipsUpcomingActions() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        var config = ReportConfiguration.standard(from: PortabilityFixtures.today, days: 14)
        config.sections = [.upcomingActions]
        config.includeAppendix = false
        let report = try service(context).buildReport(config)
        let section = try XCTUnwrap(report.sections.first { $0.id == "upcomingActions" })

        // Windows past the chosen range must be empty, not merely unlabelled.
        let tables = section.blocks.compactMap { block -> ReportTable? in
            if case .table(let table) = block { return table }
            return nil
        }
        for table in tables {
            for row in table.rows {
                XCTAssertTrue(
                    config.dateRange.contains(DateMath.mediumFormat.date(from: row[0].text) ?? PortabilityFixtures.today),
                    "an event outside the chosen range was printed"
                )
            }
        }
    }

    func testExtraPaymentSectionIsOptInAndSaysSoWhenUnspecified() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        var config = standardConfig
        config.sections.insert(.extraPaymentInsight)
        let withoutPayment = try service(context).buildReport(config)
        let section = try XCTUnwrap(withoutPayment.sections.first { $0.id == "extraPaymentInsight" })
        XCTAssertTrue(section.blocks.contains { block in
            if case .empty(let text) = block { return text.contains("No extra payment") }
            return false
        })

        let setup = try XCTUnwrap(context.fetch(FetchDescriptor<DebtAccount>()).first)
        config.extraPayment = StoredExtraPayment(
            id: UUID(),
            kind: .oneTime,
            amount: TestSupport.money("600.00"),
            effectiveDate: TestSupport.date(2054, 4, 3),
            targetDebtID: setup.id,
            sourceAccountID: nil
        )
        let withPayment = try service(context).buildReport(config)
        let filled = try XCTUnwrap(withPayment.sections.first { $0.id == "extraPaymentInsight" })
        let values = filled.blocks.compactMap { block -> [ReportKeyValue]? in
            if case .keyValues(let kv) = block { return kv }
            return nil
        }.flatMap { $0 }
        XCTAssertTrue(values.contains { $0.label == "Extra payment" })
    }

    func testFullDetailAddsThePaycheckScheduleToTheAppendix() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        var config = standardConfig
        config.detailLevel = .full
        let report = try service(context).buildReport(config)
        let appendix = try XCTUnwrap(report.sections.first { $0.id == "appendix" })
        XCTAssertTrue(appendix.blocks.contains { block in
            if case .subheading(let text) = block { return text == "Paycheck schedule" }
            return false
        })
    }

    // MARK: - PDF layout

    func testPDFIsMultiPageWithHeadersAndPageNumbers() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(context)
        try PortabilityFixtures.addHistory(context, setup: setup)

        var config = standardConfig
        config.detailLevel = .full
        let data = try service(context).pdfData(config)
        let document = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertGreaterThan(document.pageCount, 1, "a full-detail report spans pages")

        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let text = page.string ?? ""
            XCTAssertTrue(text.contains("Page \(index + 1) of \(document.pageCount)"),
                          "page \(index + 1) is missing a correct page number")
            XCTAssertTrue(text.contains("Financial report"), "page \(index + 1) is missing its header")
            // Page geometry is US Letter on every page.
            let bounds = page.bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, FinancialReportRenderer.pageSize.width, accuracy: 1)
            XCTAssertEqual(bounds.height, FinancialReportRenderer.pageSize.height, accuracy: 1)
        }
    }

    func testPageNumbersMatchTheActualPageCount() throws {
        // The two-pass renderer must agree with itself: the total printed in
        // the footer is computed before any page is drawn.
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        for level in ReportConfiguration.DetailLevel.allCases {
            var config = standardConfig
            config.detailLevel = level
            let data = try service(context).pdfData(config)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let firstPage = try XCTUnwrap(document.page(at: 0)).string ?? ""
            XCTAssertTrue(
                firstPage.contains("Page 1 of \(document.pageCount)"),
                "\(level.rawValue): footer claims a different total than the document has"
            )
        }
    }

    func testLongLabelsWrapInsteadOfOverflowing() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let long = String(repeating: "Very long debt name that keeps going ", count: 4)
        context.insert(PortabilityFixtures.debt(
            planID: "D8", name: long, balance: "1000.00", apr: "0.19",
            minimum: "40.00", dueDay: 8, priority: 8, type: .creditCard
        ))
        try context.save()

        let data = try service(context).pdfData(standardConfig)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()

        // The name survives (wrapped), rather than being clipped away.
        XCTAssertTrue(text.contains("Very long debt name"))
        // And nothing was drawn outside the page box.
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let content = page.bounds(for: .mediaBox)
            XCTAssertTrue(content.contains(page.bounds(for: .cropBox)))
        }
    }

    func testChartRanksBarsLightToDarkByMagnitude() throws {
        // The ramp is sequential: the largest magnitude takes the darkest step,
        // which is what keeps the ordering readable in a grayscale print.
        XCTAssertEqual(ReportCanvas.magnitudeRanks([300, 100, 200]), [2, 0, 1])
        XCTAssertEqual(ReportCanvas.magnitudeRanks([5, 5]), [0, 1])
        XCTAssertEqual(ReportCanvas.magnitudeRanks([]), [])
    }

    func testChartWithAllZeroValuesStillRenders() throws {
        let report = FinancialReport(
            title: "Financial report",
            subtitle: "Test",
            generatedAt: PortabilityFixtures.today,
            range: ReportConfiguration.DateRange(
                start: PortabilityFixtures.today, end: PortabilityFixtures.today
            ),
            sections: [ReportSection(id: "s", title: "Chart", blocks: [
                .chart(ReportMagnitudeChart(
                    title: "Estimated interest paid",
                    caption: nil,
                    bars: [
                        .init(label: "Fastest Safe", value: 0, displayValue: "$0"),
                        .init(label: "Balanced", value: 0, displayValue: "$0", isRecommended: true),
                        .init(label: "More Cushion", value: 0, displayValue: "$0")
                    ]
                ))
            ])],
            disclaimer: ["Estimates only."]
        )
        let document = try XCTUnwrap(PDFDocument(data: FinancialReportRenderer.pdfData(for: report)))
        let text = try XCTUnwrap(document.page(at: 0)).string ?? ""
        XCTAssertTrue(text.contains("Fastest Safe"))
        XCTAssertTrue(text.contains("$0"), "a zero bar still shows its value")
    }

    func testPDFMetadataCarriesNoUserData() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)
        let data = try service(context).pdfData(standardConfig)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let attributes = document.documentAttributes ?? [:]

        let joined = attributes.values.compactMap { $0 as? String }.joined(separator: " ")
        for label in ["Blue card", "Everyday checking", "Clear the cards"] {
            XCTAssertFalse(joined.contains(label), "PDF metadata leaked \(label)")
        }
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String,
                       "Payday Playbook financial report")
    }

    // MARK: - File lifecycle (A-11)

    func testGeneratedReportLivesInTheTempReportsDirectory() throws {
        FinancialReportService.discardGeneratedReports()
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)

        let url = try service(context).generate(standardConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertTrue(url.path.contains("/tmp/"), "reports stay in temporary storage, not Documents")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Reports")

        FinancialReportService.discardGeneratedReports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "closing the report screen must delete the file")
    }

    func testColdLaunchPurgeClearsReportsButKeepsSafetyBackups() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)
        let report = try service(context).generate(standardConfig)
        let safety = try BackupPortingService(
            context: context, dateProvider: PortabilityFixtures.dateProvider
        ).writeSafetyBackup()

        PortableFileStore.purgeTransient()

        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.path),
                      "a safety net that evaporates on relaunch is not a safety net")
        PortableFileStore.purge(.safety)
    }

    func testFailedGenerationLeavesTheStoreUnchanged() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(context)
        try PortabilityFixtures.addHistory(context, setup: setup)
        let before = try ExportService.buildBackup(context: context)

        // Every detail level and every section combination, generated back to
        // back: report generation is a read, and must never write.
        for level in ReportConfiguration.DetailLevel.allCases {
            var config = standardConfig
            config.detailLevel = level
            config.sections = Set(ReportConfiguration.Section.allCases)
            _ = try service(context).pdfData(config)
        }

        let after = try ExportService.buildBackup(context: context)
        XCTAssertEqual(
            try encoded(before), try encoded(after),
            "generating a report must not modify a single row"
        )
        FinancialReportService.discardGeneratedReports()
    }

    // MARK: - Helpers

    private func encoded(_ backup: ExportService.Backup) throws -> String {
        var object = try PortabilityFixtures.XCTUnwrapDictionary(
            try PortableCoding.encoder().encode(backup)
        )
        object["exportedAt"] = nil
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func pageCount(_ data: Data) throws -> Int {
        try XCTUnwrap(PDFDocument(data: data)).pageCount
    }

    /// Everything the report would print, as one string.
    private func renderedText(of report: FinancialReport) -> String {
        var parts: [String] = [report.title, report.subtitle]
        for section in report.sections {
            parts.append(section.title)
            for block in section.blocks {
                switch block {
                case .paragraph(let text), .subheading(let text), .empty(let text):
                    parts.append(text)
                case .bullets(let items):
                    parts.append(contentsOf: items)
                case .keyValues(let values):
                    parts.append(contentsOf: values.flatMap { [$0.label, $0.value, $0.note ?? ""] })
                case .table(let table):
                    parts.append(contentsOf: table.columns.map(\.title))
                    parts.append(contentsOf: table.rows.flatMap { $0.map(\.text) })
                    parts.append(table.footnote ?? "")
                    parts.append(table.truncationNote ?? "")
                case .callout(let callout):
                    parts.append(callout.title)
                    parts.append(contentsOf: callout.lines)
                case .chart(let chart):
                    parts.append(chart.title)
                    parts.append(contentsOf: chart.bars.flatMap { [$0.label, $0.displayValue] })
                }
            }
        }
        parts.append(contentsOf: report.disclaimer)
        return parts.joined(separator: "\n")
    }
}
