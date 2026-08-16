import Foundation
import UIKit

/// Draws a `FinancialReport` as a multi-page US Letter PDF (V3-11).
///
/// **Two passes, one layout.** Page numbers read "Page 2 of 7", which means the
/// total must be known before the first page is drawn. Rather than keeping a
/// separate measuring implementation — which would drift from the drawing one
/// and start lying about page counts — the same composer runs twice against
/// `ReportCanvas`: once with no graphics context, where every draw call is a
/// no-op and only the cursor moves, then once for real.
///
/// Nothing here logs. A report's contents are the user's whole financial
/// position, and a rendering trace would put it in the device console (V3-13).
enum FinancialReportRenderer {

    // MARK: - Page geometry

    /// US Letter at 72dpi. Fixed rather than locale-derived: the report is a
    /// document the user may print or email, and a page that silently changes
    /// size with the region setting makes layout bugs unreproducible.
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54
    static let headerHeight: CGFloat = 34
    static let footerHeight: CGFloat = 28

    // MARK: - Palette
    //
    // Print-first, light surface only: this is ink on paper, so there is no
    // dark mode to satisfy. The bar ramp is a single hue stepped light → dark
    // by magnitude, validated for monotone lightness against a white surface,
    // which is what keeps the ranking readable when the page is printed in
    // grayscale.

    enum Ink {
        static let primary = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        static let secondary = UIColor(red: 0.34, green: 0.34, blue: 0.31, alpha: 1)
        static let muted = UIColor(red: 0.53, green: 0.52, blue: 0.49, alpha: 1)
        static let hairline = UIColor(red: 0.85, green: 0.84, blue: 0.82, alpha: 1)
        static let rowTint = UIColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1)
        /// Status ink. Always paired with explicit text (a minus sign, the word
        /// "Needs input", a titled callout) so meaning never rests on color.
        static let attention = UIColor(red: 0.64, green: 0.15, blue: 0.16, alpha: 1)
        static let cautionFill = UIColor(red: 0.99, green: 0.96, blue: 0.93, alpha: 1)
        static let infoFill = UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    }

    /// Sequential ramp, light → dark. Three steps of one hue; validated for
    /// monotone lightness, adjacent-step separation, and light-end contrast
    /// against white paper.
    static let barRamp = [
        UIColor(red: 0.427, green: 0.655, blue: 0.925, alpha: 1),  // #6da7ec
        UIColor(red: 0.165, green: 0.471, blue: 0.839, alpha: 1),  // #2a78d6
        UIColor(red: 0.063, green: 0.259, blue: 0.506, alpha: 1)   // #104281
    ]

    enum Font {
        static let title = UIFont.systemFont(ofSize: 22, weight: .semibold)
        static let subtitle = UIFont.systemFont(ofSize: 11, weight: .regular)
        static let section = UIFont.systemFont(ofSize: 15, weight: .semibold)
        static let subheading = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        static let body = UIFont.systemFont(ofSize: 10, weight: .regular)
        static let keyLabel = UIFont.systemFont(ofSize: 10, weight: .regular)
        static let keyValue = UIFont.systemFont(ofSize: 10, weight: .medium)
        static let keyValueStrong = UIFont.systemFont(ofSize: 11, weight: .semibold)
        static let tableHeader = UIFont.systemFont(ofSize: 8.5, weight: .semibold)
        static let tableCell = UIFont.systemFont(ofSize: 9, weight: .regular)
        static let tableCellStrong = UIFont.systemFont(ofSize: 9, weight: .semibold)
        static let chrome = UIFont.systemFont(ofSize: 8, weight: .regular)
        static let note = UIFont.systemFont(ofSize: 8.5, weight: .regular)
    }

    // MARK: - Entry point

    static func pdfData(for report: FinancialReport) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)

        // Pass 1: lay out with no context to learn the page count.
        let measuring = ReportCanvas(report: report, context: nil, totalPages: nil)
        compose(report, into: measuring)
        let total = max(measuring.pageNumber, 1)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            // Deliberately generic. PDF metadata travels with the file and is
            // read by every viewer and indexer, so it carries no user data.
            kCGPDFContextTitle as String: "Payday Playbook financial report",
            kCGPDFContextCreator as String: "Payday Playbook"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { context in
            let canvas = ReportCanvas(report: report, context: context, totalPages: total)
            compose(report, into: canvas)
            canvas.finishIfNeeded()
        }
    }

    // MARK: - Composition

    private static func compose(_ report: FinancialReport, into canvas: ReportCanvas) {
        canvas.beginPage()
        canvas.drawCoverBlock()

        for section in report.sections {
            canvas.drawSectionTitle(section.title)
            for block in section.blocks {
                canvas.draw(block)
            }
            canvas.advance(10)
        }

        canvas.drawDisclaimer(report.disclaimer)
    }
}

// MARK: - Canvas

/// Cursor, pagination, and drawing primitives.
///
/// `context == nil` is the measuring pass: geometry advances identically and
/// nothing is painted, so page counts come from the same code that draws.
final class ReportCanvas {
    typealias R = FinancialReportRenderer

    private let report: FinancialReport
    private let context: UIGraphicsPDFRendererContext?
    private let totalPages: Int?

    private(set) var pageNumber = 0
    private var y: CGFloat = 0
    private var pageStarted = false

    private let contentRect: CGRect

    init(report: FinancialReport, context: UIGraphicsPDFRendererContext?, totalPages: Int?) {
        self.report = report
        self.context = context
        self.totalPages = totalPages
        self.contentRect = CGRect(
            x: R.margin,
            y: R.margin + R.headerHeight,
            width: R.pageSize.width - R.margin * 2,
            height: R.pageSize.height - R.margin * 2 - R.headerHeight - R.footerHeight
        )
    }

    var width: CGFloat { contentRect.width }
    private var remaining: CGFloat { contentRect.maxY - y }

    // MARK: Pages

    func beginPage() {
        pageNumber += 1
        context?.beginPage()
        pageStarted = true
        y = contentRect.minY
        drawHeader()
        drawFooter()
    }

    func finishIfNeeded() {
        // The measuring pass never opens a real page; the drawing pass always
        // has one open by the time it gets here.
        _ = pageStarted
    }

    /// Starts a new page unless `height` still fits. Callers pass the height of
    /// the smallest unit that must not be split — a heading plus its first
    /// line, a table header plus one row.
    private func ensureRoom(for height: CGFloat) {
        if height > remaining { beginPage() }
    }

    func advance(_ dy: CGFloat) { y += dy }

    private func drawHeader() {
        guard context != nil else { return }
        let top = R.margin
        drawString(report.title, font: R.Font.chrome, color: R.Ink.muted,
                   in: CGRect(x: R.margin, y: top, width: contentRect.width * 0.6, height: 12))
        drawString(report.subtitle, font: R.Font.chrome, color: R.Ink.muted,
                   in: CGRect(x: R.margin + contentRect.width * 0.6, y: top,
                              width: contentRect.width * 0.4, height: 12),
                   alignment: .right)
        hairline(atY: top + 16)
    }

    private func drawFooter() {
        guard context != nil else { return }
        let footerY = R.pageSize.height - R.margin - 12
        hairline(atY: footerY - 6)
        let page = totalPages.map { "Page \(pageNumber) of \($0)" } ?? "Page \(pageNumber)"
        drawString(page, font: R.Font.chrome, color: R.Ink.muted,
                   in: CGRect(x: R.margin, y: footerY, width: contentRect.width, height: 12),
                   alignment: .center)
        drawString("Estimates — not a statement from any lender",
                   font: R.Font.chrome, color: R.Ink.muted,
                   in: CGRect(x: R.margin, y: footerY, width: contentRect.width, height: 12),
                   alignment: .right)
    }

    // MARK: Cover

    func drawCoverBlock() {
        let titleHeight = height(of: report.title, font: R.Font.title, width: width)
        ensureRoom(for: titleHeight + 40)
        drawString(report.title, font: R.Font.title, color: R.Ink.primary,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: titleHeight))
        y += titleHeight + 4

        let line = "\(report.subtitle) · Generated \(DateMath.mediumString(report.generatedAt))"
        let subHeight = height(of: line, font: R.Font.subtitle, width: width)
        drawString(line, font: R.Font.subtitle, color: R.Ink.secondary,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: subHeight))
        y += subHeight + 14
        hairline(atY: y)
        y += 14
    }

    // MARK: Sections

    func drawSectionTitle(_ title: String) {
        let titleHeight = height(of: title, font: R.Font.section, width: width)
        // A section heading alone at the foot of a page is an orphan; reserve
        // room for the heading and something under it.
        ensureRoom(for: titleHeight + 34)
        y += 6
        drawString(title, font: R.Font.section, color: R.Ink.primary,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: titleHeight))
        y += titleHeight + 4
        hairline(atY: y)
        y += 10
    }

    func draw(_ block: ReportBlock) {
        switch block {
        case .paragraph(let text): drawParagraph(text, font: R.Font.body, color: R.Ink.secondary)
        case .subheading(let text): drawSubheading(text)
        case .keyValues(let values): drawKeyValues(values)
        case .table(let table): drawTable(table)
        case .bullets(let items): drawBullets(items)
        case .callout(let callout): drawCallout(callout)
        case .chart(let chart): drawChart(chart)
        case .empty(let text): drawEmpty(text)
        }
    }

    private func drawSubheading(_ text: String) {
        let h = height(of: text, font: R.Font.subheading, width: width)
        // Reserve enough for the subheading *and* the shape that normally
        // follows it — a table header plus a row, or two key-value lines.
        // Reserving only the heading's own height stranded "Payments on this
        // payday" at the foot of a page with its table overleaf.
        ensureRoom(for: h + 58)
        y += 6
        drawString(text, font: R.Font.subheading, color: R.Ink.primary,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: h))
        y += h + 6
    }

    private func drawParagraph(_ text: String, font: UIFont, color: UIColor) {
        let h = height(of: text, font: font, width: width)
        ensureRoom(for: min(h, 40))
        drawString(text, font: font, color: color,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: h))
        y += h + 8
    }

    private func drawEmpty(_ text: String) {
        let h = height(of: text, font: R.Font.body, width: width - 16)
        ensureRoom(for: h + 16)
        fill(CGRect(x: contentRect.minX, y: y, width: width, height: h + 12), color: R.Ink.rowTint)
        drawString(text, font: R.Font.body, color: R.Ink.muted,
                   in: CGRect(x: contentRect.minX + 8, y: y + 6, width: width - 16, height: h))
        y += h + 20
    }

    private func drawBullets(_ items: [String]) {
        for item in items {
            let textWidth = width - 14
            let h = height(of: item, font: R.Font.body, width: textWidth)
            ensureRoom(for: h + 6)
            drawString("•", font: R.Font.body, color: R.Ink.muted,
                       in: CGRect(x: contentRect.minX, y: y, width: 10, height: 12))
            drawString(item, font: R.Font.body, color: R.Ink.secondary,
                       in: CGRect(x: contentRect.minX + 14, y: y, width: textWidth, height: h))
            y += h + 5
        }
        y += 4
    }

    private func drawKeyValues(_ values: [ReportKeyValue]) {
        let labelWidth = width * 0.52
        let valueWidth = width - labelWidth
        for value in values {
            let labelHeight = height(of: value.label, font: R.Font.keyLabel, width: labelWidth)
            let valueFont = value.emphasis == .strong ? R.Font.keyValueStrong : R.Font.keyValue
            let valueHeight = height(of: value.value, font: valueFont, width: valueWidth)
            let noteHeight = value.note.map { height(of: $0, font: R.Font.note, width: width) } ?? 0
            let rowHeight = max(labelHeight, valueHeight) + (noteHeight > 0 ? noteHeight + 2 : 0)
            ensureRoom(for: rowHeight + 6)

            drawString(value.label, font: R.Font.keyLabel, color: R.Ink.secondary,
                       in: CGRect(x: contentRect.minX, y: y, width: labelWidth, height: labelHeight))
            drawString(value.value, font: valueFont, color: color(for: value.emphasis),
                       in: CGRect(x: contentRect.minX + labelWidth, y: y,
                                  width: valueWidth, height: valueHeight),
                       alignment: .right)
            var rowY = y + max(labelHeight, valueHeight)
            if let note = value.note {
                drawString(note, font: R.Font.note, color: R.Ink.muted,
                           in: CGRect(x: contentRect.minX, y: rowY + 1, width: width, height: noteHeight),
                           alignment: .right)
                rowY += noteHeight + 2
            }
            y = rowY + 5
        }
        y += 4
    }

    private func drawCallout(_ callout: ReportCallout) {
        let inset: CGFloat = 10
        let textWidth = width - inset * 2
        // The tone marker is a character, not just a fill color: a grayscale
        // print or a colorblind reader must still see which callouts are
        // cautions.
        let marker = callout.tone == .caution ? "!  " : "i  "
        let titleText = marker + callout.title
        let titleHeight = height(of: titleText, font: R.Font.subheading, width: textWidth)
        let lineHeights = callout.lines.map { height(of: $0, font: R.Font.body, width: textWidth) }
        let boxHeight = inset * 2 + titleHeight + lineHeights.reduce(0) { $0 + $1 + 3 }

        ensureRoom(for: min(boxHeight, contentRect.height))
        fill(CGRect(x: contentRect.minX, y: y, width: width, height: boxHeight),
             color: callout.tone == .caution ? R.Ink.cautionFill : R.Ink.infoFill)
        // Accent rule on the leading edge, a second non-color-dependent cue.
        fill(CGRect(x: contentRect.minX, y: y, width: 3, height: boxHeight),
             color: callout.tone == .caution ? R.Ink.attention : R.Ink.muted)

        var innerY = y + inset
        drawString(titleText, font: R.Font.subheading,
                   color: callout.tone == .caution ? R.Ink.attention : R.Ink.primary,
                   in: CGRect(x: contentRect.minX + inset, y: innerY, width: textWidth, height: titleHeight))
        innerY += titleHeight + 3
        for (index, line) in callout.lines.enumerated() {
            drawString(line, font: R.Font.body, color: R.Ink.secondary,
                       in: CGRect(x: contentRect.minX + inset, y: innerY,
                                  width: textWidth, height: lineHeights[index]))
            innerY += lineHeights[index] + 3
        }
        y += boxHeight + 10
    }

    // MARK: Tables

    private func drawTable(_ table: ReportTable) {
        guard !table.columns.isEmpty else { return }
        let widths = columnWidths(for: table)
        let headerHeight = rowHeight(
            cells: table.columns.map { ReportCell($0.title) },
            widths: widths, font: R.Font.tableHeader
        )

        var drewHeader = false
        func drawHeaderRow() {
            fill(CGRect(x: contentRect.minX, y: y, width: width, height: headerHeight + 6),
                 color: R.Ink.rowTint)
            var x = contentRect.minX
            for (index, column) in table.columns.enumerated() {
                drawString(column.title, font: R.Font.tableHeader, color: R.Ink.secondary,
                           in: CGRect(x: x + 4, y: y + 3, width: widths[index] - 8, height: headerHeight),
                           alignment: column.alignment == .trailing ? .right : .left)
                x += widths[index]
            }
            y += headerHeight + 6
            hairline(atY: y)
            y += 3
            drewHeader = true
        }

        // A header with no row under it tells the reader nothing, so the
        // header and the first row are placed together; on a page break the
        // header is repeated rather than left behind.
        let firstRowHeight = table.rows.first.map {
            rowHeight(cells: $0, widths: widths, font: R.Font.tableCell)
        } ?? 0
        ensureRoom(for: headerHeight + firstRowHeight + 16)
        drawHeaderRow()

        for (rowIndex, row) in table.rows.enumerated() {
            let h = rowHeight(cells: row, widths: widths, font: R.Font.tableCell)
            if h + 6 > remaining {
                beginPage()
                drewHeader = false
                drawHeaderRow()
            }
            if rowIndex.isMultiple(of: 2) {
                fill(CGRect(x: contentRect.minX, y: y - 2, width: width, height: h + 5),
                     color: R.Ink.rowTint.withAlphaComponent(0.45))
            }
            var x = contentRect.minX
            for (index, cell) in row.enumerated() where index < widths.count {
                let column = table.columns[index]
                let font = cell.emphasis == .strong ? R.Font.tableCellStrong : R.Font.tableCell
                drawString(cell.text, font: font, color: color(for: cell.emphasis),
                           in: CGRect(x: x + 4, y: y, width: widths[index] - 8, height: h),
                           alignment: column.alignment == .trailing ? .right : .left)
                x += widths[index]
            }
            y += h + 4
        }
        _ = drewHeader

        y += 2
        if let note = table.truncationNote {
            drawNoteLine(note, color: R.Ink.attention)
        }
        if let footnote = table.footnote {
            drawNoteLine(footnote, color: R.Ink.muted)
        }
        y += 6
    }

    private func drawNoteLine(_ text: String, color: UIColor) {
        let h = height(of: text, font: R.Font.note, width: width)
        ensureRoom(for: h + 4)
        drawString(text, font: R.Font.note, color: color,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: h))
        y += h + 3
    }

    /// Proportional widths from the columns' weights, with a floor so a
    /// low-weight column never collapses to nothing when a table has many
    /// columns.
    private func columnWidths(for table: ReportTable) -> [CGFloat] {
        let totalWeight = table.columns.reduce(0.0) { $0 + max($1.weight, 0.1) }
        let minimum: CGFloat = 34
        var widths = table.columns.map { column in
            max(minimum, width * CGFloat(max(column.weight, 0.1) / totalWeight))
        }
        // Floors can push the row past the page; scale back proportionally.
        let sum = widths.reduce(0, +)
        if sum > width {
            let scale = width / sum
            widths = widths.map { $0 * scale }
        }
        return widths
    }

    private func rowHeight(cells: [ReportCell], widths: [CGFloat], font: UIFont) -> CGFloat {
        var tallest: CGFloat = 12
        for (index, cell) in cells.enumerated() where index < widths.count {
            // Long names wrap inside their column rather than being clipped or
            // pushing the table off the page.
            tallest = max(tallest, height(of: cell.text, font: font, width: widths[index] - 8))
        }
        return tallest
    }

    // MARK: Chart

    /// Horizontal bars, one measure, sequential shading by magnitude.
    ///
    /// Horizontal because the category labels are words ("More Cushion"), and
    /// rotated or truncated axis labels are the most common way a small chart
    /// becomes unreadable. Every bar is directly labeled with its value, so the
    /// chart needs no axis ticks and no legend.
    private func drawChart(_ chart: ReportMagnitudeChart) {
        let titleHeight = height(of: chart.title, font: R.Font.subheading, width: width)
        let barHeight: CGFloat = 14
        let barGap: CGFloat = 8
        let plotHeight = CGFloat(chart.bars.count) * (barHeight + barGap)
        let captionHeight = chart.caption.map { height(of: $0, font: R.Font.note, width: width) } ?? 0
        ensureRoom(for: titleHeight + plotHeight + captionHeight + 22)

        drawString(chart.title, font: R.Font.subheading, color: R.Ink.primary,
                   in: CGRect(x: contentRect.minX, y: y, width: width, height: titleHeight))
        y += titleHeight + 6

        let labelWidth = width * 0.30
        let valueWidth: CGFloat = 74
        let plotWidth = width - labelWidth - valueWidth - 12
        let maximum = chart.maximum

        // Rank drives shade: the largest magnitude gets the darkest step, so
        // the ordering survives a grayscale print.
        let ranks = Self.magnitudeRanks(chart.bars.map(\.value))

        // Recessive baseline: one hairline, no gridlines. Three direct-labeled
        // bars do not need a scale to be read.
        let baselineX = contentRect.minX + labelWidth
        if context != nil {
            fill(CGRect(x: baselineX, y: y, width: 0.5, height: plotHeight - barGap + 2),
                 color: R.Ink.hairline)
        }

        for (index, bar) in chart.bars.enumerated() {
            let label = bar.label + (bar.isRecommended ? " (recommended)" : "")
            drawString(label, font: R.Font.tableCell, color: R.Ink.secondary,
                       in: CGRect(x: contentRect.minX, y: y + 2, width: labelWidth - 6, height: barHeight))

            let fraction = maximum > 0 ? CGFloat(bar.value / maximum) : 0
            let length = max(fraction * plotWidth, bar.value > 0 ? 2 : 0)
            if length > 0 {
                let rect = CGRect(x: baselineX + 1, y: y + 1, width: length, height: barHeight - 2)
                // 4pt rounded data-end on the trailing edge only; the end at
                // the baseline stays square so the bar reads as anchored.
                let path = UIBezierPath(
                    roundedRect: rect,
                    byRoundingCorners: [.topRight, .bottomRight],
                    cornerRadii: CGSize(width: 4, height: 4)
                )
                if context != nil {
                    barRampColor(rank: ranks[index], of: chart.bars.count).setFill()
                    path.fill()
                }
            }
            // Values wear text ink, never the bar's color.
            drawString(bar.displayValue, font: R.Font.tableCellStrong, color: R.Ink.primary,
                       in: CGRect(x: baselineX + plotWidth + 6, y: y + 2,
                                  width: valueWidth, height: barHeight),
                       alignment: .right)
            y += barHeight + barGap
        }

        if let caption = chart.caption {
            drawString(caption, font: R.Font.note, color: R.Ink.muted,
                       in: CGRect(x: contentRect.minX, y: y, width: width, height: captionHeight))
            y += captionHeight
        }
        y += 10
    }

    /// Ordinal position of each value from smallest (0) to largest.
    static func magnitudeRanks(_ values: [Double]) -> [Int] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var ranks = Array(repeating: 0, count: values.count)
        for (rank, entry) in sorted.enumerated() { ranks[entry.offset] = rank }
        return ranks
    }

    private func barRampColor(rank: Int, of count: Int) -> UIColor {
        guard count > 1 else { return R.barRamp[1] }
        // Spread the available ramp steps across however many bars there are,
        // keeping the light end at the smallest magnitude.
        let position = Double(rank) / Double(count - 1)
        let index = Int((position * Double(R.barRamp.count - 1)).rounded())
        return R.barRamp[min(max(index, 0), R.barRamp.count - 1)]
    }

    // MARK: Disclaimer

    func drawDisclaimer(_ lines: [String]) {
        let inset: CGFloat = 10
        let textWidth = width - inset * 2
        let titleHeight = height(of: "About these numbers", font: R.Font.subheading, width: textWidth)
        let heights = lines.map { height(of: $0, font: R.Font.note, width: textWidth) }
        let boxHeight = inset * 2 + titleHeight + heights.reduce(0) { $0 + $1 + 4 }
        ensureRoom(for: boxHeight)

        fill(CGRect(x: contentRect.minX, y: y, width: width, height: boxHeight), color: R.Ink.infoFill)
        var innerY = y + inset
        drawString("About these numbers", font: R.Font.subheading, color: R.Ink.primary,
                   in: CGRect(x: contentRect.minX + inset, y: innerY, width: textWidth, height: titleHeight))
        innerY += titleHeight + 4
        for (index, line) in lines.enumerated() {
            drawString(line, font: R.Font.note, color: R.Ink.secondary,
                       in: CGRect(x: contentRect.minX + inset, y: innerY, width: textWidth, height: heights[index]))
            innerY += heights[index] + 4
        }
        y += boxHeight
    }

    // MARK: Primitives

    private func color(for emphasis: ReportEmphasis) -> UIColor {
        switch emphasis {
        case .normal: return R.Ink.primary
        case .strong: return R.Ink.primary
        case .attention: return R.Ink.attention
        }
    }

    private func attributes(font: UIFont, color: UIColor, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func drawString(
        _ text: String,
        font: UIFont,
        color: UIColor,
        in rect: CGRect,
        alignment: NSTextAlignment = .left
    ) {
        guard context != nil, !text.isEmpty else { return }
        NSAttributedString(string: text, attributes: attributes(font: font, color: color, alignment: alignment))
            .draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    private func height(of text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let bounds = NSAttributedString(
            string: text,
            attributes: attributes(font: font, color: .black, alignment: .left)
        ).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height)
    }

    private func fill(_ rect: CGRect, color: UIColor) {
        guard let context else { return }
        color.setFill()
        context.cgContext.fill(rect)
    }

    private func hairline(atY lineY: CGFloat) {
        fill(CGRect(x: contentRect.minX, y: lineY, width: width, height: 0.5), color: R.Ink.hairline)
    }
}
