import Cocoa

// Fills get their own colours per appearance. The label colours invert with the
// appearance and are meant for text on the card, so painting one as a block
// yields a light slab in dark mode with no room for text on top of it.
enum Palette {
    static let tileFill = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    static let trackFill = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.11))
    static let emptyTick = dynamic(light: NSColor(white: 0, alpha: 0.22), dark: NSColor(white: 1, alpha: 0.26))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.11))
    // A tint, never a solid: the row text sits on top of it and must stay legible.
    static let leaderFill = NSColor.controlAccentColor.withAlphaComponent(0.26)
    static let peakFill = NSColor.controlAccentColor.withAlphaComponent(0.92)

    // System colours so every hue adapts to the appearance. Ordered so no two
    // neighbours land in the same part of the wheel.
    static let categorical: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink,
        .systemTeal, .systemIndigo, .systemRed, .systemYellow,
    ]

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// All number formatting and typography lives here, so no view has to know which
// metric is in play and every value that can change keeps monospaced digits.
enum Format {
    // MARK: numbers

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }

    static func count(_ n: Int) -> String { countFormatter.string(from: NSNumber(value: n)) ?? String(n) }

    static func cost(_ d: Double) -> String { String(format: "$%.2f", d) }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func value(_ tokenTotal: Int, _ costTotal: Double, _ metric: Metric) -> String {
        metric == .cost ? cost(costTotal) : tokens(tokenTotal)
    }

    static func magnitude(_ tokenTotal: Int, _ costTotal: Double, _ metric: Metric) -> Double {
        metric == .cost ? costTotal : Double(tokenTotal)
    }

    static func listValue(_ entry: RankedEntry, _ metric: Metric) -> String {
        value(entry.tokens, entry.cost, metric)
    }

    static func listMagnitude(_ entry: RankedEntry, _ metric: Metric) -> Double {
        magnitude(entry.tokens, entry.cost, metric)
    }

    static func heroValue(_ snapshot: DashboardSnapshot) -> String {
        value(snapshot.tokens.total, snapshot.cost.total, snapshot.metric)
    }

    static func perDay(_ snapshot: DashboardSnapshot) -> String {
        let days = Double(max(1, snapshot.activeDays))
        return snapshot.metric == .cost
            ? cost(snapshot.cost.total / days)
            : tokens(Int(Double(snapshot.tokens.total) / days))
    }

    static func today(_ snapshot: DashboardSnapshot) -> String {
        guard let day = snapshot.days.first(where: { $0.day == dayKey }) else { return value(0, 0, snapshot.metric) }
        return value(day.tokens, day.cost, snapshot.metric)
    }

    static var dayKey: String { dayKeyFormatter.string(from: Date()) }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // Same setup as Snapshot.swift, so "today" compares against the same keys.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: type

    // Sizes come from text styles. The mono-digit variants keep a right-aligned
    // column still while its value changes.
    static func text(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    static func mono(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    static let heading = text(.subheadline, weight: .semibold)
    static let tileValue = mono(.title2, weight: .semibold)
    static let rowText = text(.body)
    static let rowTextStrong = text(.body, weight: .semibold)
    static let rowValue = mono(.body, weight: .medium)
    static let rowValueStrong = mono(.body, weight: .semibold)
    static let detail = mono(.footnote)
    static let caption = text(.caption1)
    static let chart = mono(.footnote)

    // The hero is the largest type in the panel, so its tracking is the tightest.
    static func hero(_ number: String) -> NSAttributedString {
        let size = NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
        return NSAttributedString(string: number, attributes: [
            .font: mono(.largeTitle, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .kern: -0.02 * size,
        ])
    }
}

// The popover's own card. Blur unless the user asked for reduced transparency,
// in which case an opaque window background stands in.
final class CardView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        state = .active
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            material = .windowBackground
            blendingMode = .withinWindow
        } else {
            material = .popover
            blendingMode = .behindWindow
        }
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

// The mark from the header of the reference: a rounded square holding the pi
// glyph. Drawn as text rather than as a bitmap so it stays crisp at any size and
// follows the appearance without a second asset.
final class LogoView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        Palette.trackFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let glyph = NSAttributedString(string: "π", attributes: [
            .font: NSFont.systemFont(ofSize: bounds.height * 0.66, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let height = glyph.size().height
        glyph.draw(in: NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height))
    }

    // The glyph colour is read at draw time, so only a redraw is needed.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class SectionHeaderView: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = Format.heading
        textColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

// Caption top left, number bottom right, so numbers share a column across the grid.
final class MetricTileView: NSView {
    private let icon = NSImageView()
    private let color: NSColor

    init(caption: String, value: String, color: NSColor, symbol: String? = nil) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.imageScaling = .scaleProportionallyDown
        applyColors()
        let captionField = NSTextField(labelWithString: caption)
        captionField.font = Format.caption
        captionField.textColor = .secondaryLabelColor
        let valueField = NSTextField(labelWithString: value)
        valueField.font = Format.tileValue
        valueField.textColor = .labelColor
        valueField.alignment = .right
        for field in [icon, captionField, valueField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: captionField.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 14),
            captionField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            captionField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            valueField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            valueField.topAnchor.constraint(greaterThanOrEqualTo: captionField.bottomAnchor, constant: 2),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: captionField.leadingAnchor),
        ])
    }

    // A layer colour is resolved once, so it has to be reapplied by hand when
    // the system switches between light and dark.
    private func applyColors() {
        layer?.backgroundColor = Palette.tileFill.cgColor
        layer?.borderColor = Palette.hairline.cgColor
        icon.contentTintColor = color
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Resolving the colours inside the new appearance is what makes a live
        // light/dark switch repaint the layers, not just the first setup.
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// One row of a ranked list. The bar behind it is proportional to the value.
struct RankedRow {
    var label: String
    var text: String
    var magnitude: Double
    var detail: String?
    var symbol: String?
    var mark: LanguageMarks.Mark?

    init(_ label: String, _ text: String, _ magnitude: Double, detail: String? = nil,
         symbol: String? = nil, mark: LanguageMarks.Mark? = nil) {
        self.label = label
        self.text = text
        self.magnitude = magnitude
        self.detail = detail
        self.symbol = symbol
        self.mark = mark
    }
}

final class RankedRowView: NSView {
    private let bar = NSView()
    private let swatch = NSView()
    private let icon = NSImageView()
    private let color: NSColor
    private let fraction: CGFloat
    private let leader: Bool
    private let mark: LanguageMarks.Mark?
    private let symbol: String?

    init(row: RankedRow, fraction: CGFloat, leader: Bool, color: NSColor) {
        self.fraction = fraction
        self.leader = leader
        self.color = color
        self.mark = row.mark
        self.symbol = row.symbol
        super.init(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 4
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        swatch.addSubview(icon)
        applyColors()
        addSubview(bar)
        addSubview(swatch)

        let label = NSTextField(labelWithString: row.label)
        label.font = leader ? Format.rowTextStrong : Format.rowText
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let value = NSTextField(labelWithString: row.text)
        value.font = leader ? Format.rowValueStrong : Format.rowValue
        value.textColor = .labelColor
        value.alignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        for field in [label, value] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        var constraints = [
            icon.centerXAnchor.constraint(equalTo: swatch.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: swatch.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            swatch.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 17),
            swatch.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -8),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            value.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ]
        if let detail = row.detail {
            let line = NSTextField(labelWithString: detail)
            line.font = Format.detail
            line.textColor = .secondaryLabelColor
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            constraints += [
                line.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                line.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
                line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ]
        } else {
            constraints.append(label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func applyColors() {
        bar.layer?.backgroundColor = color.withAlphaComponent(0.22).cgColor
        if let mark = mark {
            // A real mark carries its own colour, so the badge behind it stays
            // neutral and does not fight the logo.
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            icon.image = LanguageMarks.tinted(mark, dark: dark, size: 13)
            icon.contentTintColor = nil
            swatch.layer?.backgroundColor = Palette.trackFill.cgColor
        } else {
            icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            icon.contentTintColor = color
            // A tinted badge behind a solid glyph, so the mark stays legible for
            // every hue in the palette, including the light ones.
            swatch.layer?.backgroundColor = color.withAlphaComponent(0.30).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // Frame set directly on every layout: nothing grows or animates, so Reduce
    // Motion needs no branch here.
    override func layout() {
        super.layout()
        let width = fraction <= 0 ? 0 : max(2, fraction * bounds.width)
        bar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}

final class RankedListView: NSView {
    init(rows: [RankedRow]) {
        super.init(frame: .zero)
        let maxValue = rows.map(\.magnitude).max() ?? 0
        let leader = maxValue > 0 ? rows.firstIndex { $0.magnitude == maxValue } : nil
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (index, row) in rows.enumerated() {
            let fraction = maxValue > 0 ? CGFloat(row.magnitude / maxValue) : 0
            let color = Palette.categorical[index % Palette.categorical.count]
            let view = RankedRowView(row: row, fraction: fraction, leader: index == leader, color: color)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}
