import Cocoa

// Tokens per day as horizontal bars: one labelled row per day, so any number of
// days stays readable and every value has room.
final class BarChartView: NSView {
    private let days: [DayUsage]
    private let rowHeight: CGFloat = 22
    private let rowGap: CGFloat = 4
    private let labelWidth: CGFloat = 46
    private let valueWidth: CGFloat = 58

    init(days: [DayUsage]) {
        self.days = days
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tokens per day")
        setAccessibilityValue(summary)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: CGFloat(max(1, days.count)) * (rowHeight + rowGap))
    }

    private var summary: String {
        guard let peak = days.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 else { return "No usage yet" }
        let active = days.filter { $0.tokens > 0 }.count
        return "\(active) active days, peak \(Format.tokens(peak.tokens)) on \(peak.day)"
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackX = labelWidth + 6
        let trackWidth = max(8, bounds.width - trackX - valueWidth - 6)
        let maxTokens = max(1, days.map(\.tokens).max() ?? 0)
        let peak = days.max(by: { $0.tokens < $1.tokens })?.tokens ?? 0
        for (index, day) in days.enumerated() {
            let y = CGFloat(index) * (rowHeight + rowGap)
            let barHeight = rowHeight - 6
            let barY = y + (rowHeight - barHeight) / 2
            draw(String(day.day.suffix(5)), in: NSRect(x: 0, y: barY, width: labelWidth, height: barHeight),
                 alignment: .left, color: .secondaryLabelColor)
            draw(Format.tokens(day.tokens), in: NSRect(x: bounds.width - valueWidth, y: barY, width: valueWidth, height: barHeight),
                 alignment: .right, color: .labelColor)
            if day.tokens <= 0 {
                // A 1 point tick: an empty day reads as empty, not as a missing row.
                Palette.emptyTick.setFill()
                NSBezierPath(rect: NSRect(x: trackX, y: barY, width: 1, height: barHeight)).fill()
            } else {
                let width = max(2, CGFloat(day.tokens) / CGFloat(maxTokens) * trackWidth)
                let color: NSColor = day.tokens == peak ? Palette.peakFill : Palette.trackFill
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: trackX, y: barY, width: width, height: barHeight),
                             xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    private func draw(_ text: String, in rect: NSRect, alignment: NSTextAlignment, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        NSAttributedString(string: text, attributes: [
            .font: Format.chart,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]).draw(in: rect)
    }
}

// Languages as a ring of up to five hues plus a grey "Other", with a legend that
// names each slice and its line count.
final class DonutChartView: NSView {
    private struct Slice {
        var name: String
        var lines: Int
        var color: NSColor
    }

    private let slices: [Slice]
    private let languageCount: Int

    // Five hues at most, and only here, where slices must be told apart.
    private static let palette: [NSColor] = [.controlAccentColor, .systemTeal, .systemIndigo, .systemOrange, .systemPink]

    init(languages: [LanguageEntry], top: Int = 5) {
        let head = languages.prefix(top)
        let otherLines = languages.dropFirst(top).reduce(0) { $0 + $1.lines }
        var slices = head.enumerated().map {
            Slice(name: $0.element.name, lines: $0.element.lines, color: DonutChartView.palette[$0.offset % DonutChartView.palette.count])
        }
        if otherLines > 0 { slices.append(Slice(name: "Other", lines: otherLines, color: .systemGray)) }
        self.slices = slices
        self.languageCount = languages.count
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Languages")
        setAccessibilityValue(summary)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 156) }

    private var summary: String {
        guard !slices.isEmpty else { return "No languages yet" }
        let top = slices.prefix(3).map { "\($0.name) \(Format.count($0.lines)) lines" }.joined(separator: ", ")
        return "\(languageCount) languages: \(top)"
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.height - 16, 128)
        let ring: CGFloat = 18
        let center = NSPoint(x: 12 + diameter / 2, y: bounds.height / 2)
        let total = max(1, slices.reduce(0) { $0 + $1.lines })
        var angle: CGFloat = 90
        for slice in slices {
            let sweep = 360 * CGFloat(slice.lines) / CGFloat(total)
            if slice.lines > 0 {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: diameter / 2 - ring / 2,
                               startAngle: angle, endAngle: angle - sweep, clockwise: true)
                path.lineWidth = ring
                slice.color.setStroke()
                path.stroke()
            }
            angle -= sweep
        }

        let legendX = 12 + diameter + 18
        let rowHeight: CGFloat = 18
        var y = (bounds.height - CGFloat(slices.count) * rowHeight) / 2
        // Reversed: this view is not flipped, so the last row drawn lands on top.
        for slice in slices.reversed() {
            slice.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: legendX, y: y + 4, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            let textY = y + 1
            draw(slice.name, in: NSRect(x: legendX + 16, y: textY, width: bounds.width - legendX - 16 - 62, height: rowHeight - 2),
                 alignment: .left, color: .labelColor)
            draw(Format.count(slice.lines), in: NSRect(x: bounds.width - 58, y: textY, width: 58, height: rowHeight - 2),
                 alignment: .right, color: .secondaryLabelColor)
            y += rowHeight
        }
    }

    private func draw(_ text: String, in rect: NSRect, alignment: NSTextAlignment, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [
            .font: Format.chart,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]).draw(in: rect)
    }
}
