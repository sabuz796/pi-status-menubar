import Cocoa

// A mark per row, chosen to mean something. Language and tool glyphs come from
// the row's own name, so a new language or tool still gets a sensible icon.
private func languageSymbol(_ name: String) -> String {
    switch name {
    case "TypeScript", "JavaScript", "JSON": return "curlybraces"
    case "Python", "Swift", "HTML", "C", "C++", "Rust", "Go", "Java", "Ruby":
        return "chevron.left.forwardslash.chevron.right"
    case "Markdown": return "doc.text"
    case "CSS": return "paintbrush"
    case "Shell": return "terminal"
    case "SQL": return "cylinder"
    case "Text": return "doc.plaintext"
    case "YAML", "TOML", "XML": return "list.bullet.rectangle"
    default: return "doc"
    }
}

private func toolSymbol(_ name: String) -> String {
    switch name {
    case "bash", "shell", "powershell": return "terminal"
    case "read": return "doc.text"
    case "edit": return "pencil"
    case "write": return "square.and.pencil"
    case "grep", "find", "search", "ls": return "magnifyingglass"
    case "fetch_content", "web_search", "fetch": return "globe"
    case "question", "ask_user_question", "ask_user": return "questionmark.circle"
    case "subagent", "agent": return "person.2"
    case "codemode": return "wand.and.stars"
    default:
        if name.hasPrefix("plan") { return "list.bullet.rectangle" }
        if name.hasPrefix("plannotator") { return "checkmark.seal" }
        return "wrench"
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// Shared tab body: one vertical stack inside a scroller whose document view
// starts at the top, so a long list opens on its first row.
class DashboardTabController: NSViewController {
    let stack = NSStackView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private(set) var snapshot = DashboardSnapshot()

    override func loadView() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
        ])
        view = scroll
    }

    func apply(_ snapshot: DashboardSnapshot) { self.snapshot = snapshot }

    // Rebuilt from the snapshot every time: nothing derived is kept across updates.
    func setContent(_ views: [NSView]) {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for subview in views {
            stack.addArrangedSubview(subview)
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

final class OverviewTabController: DashboardTabController {
    override func apply(_ snapshot: DashboardSnapshot) {
        super.apply(snapshot)
        let tiles: [NSView] = [
            MetricTileView(caption: "Tokens", value: Format.tokens(snapshot.tokens.total), color: Palette.categorical[0], symbol: "sum"),
            MetricTileView(caption: "Sessions", value: Format.count(snapshot.sessions), color: Palette.categorical[1], symbol: "bubble.left.and.bubble.right"),
            MetricTileView(caption: "Messages", value: Format.count(snapshot.messages), color: Palette.categorical[2], symbol: "text.bubble"),
            MetricTileView(caption: "Active Days", value: Format.count(snapshot.activeDays), color: Palette.categorical[3], symbol: "calendar"),
            MetricTileView(caption: "Avg/Day", value: Format.perDay(snapshot), color: Palette.categorical[4], symbol: "chart.line.uptrend.xyaxis"),
            MetricTileView(caption: "Today", value: Format.today(snapshot), color: Palette.categorical[5], symbol: "clock"),
        ]
        var content: [NSView] = [
            tileRow(Array(tiles[0..<3])),
            tileRow(Array(tiles[3..<6])),
            SectionHeaderView("Tokens per day"),
            BarChartView(days: snapshot.days),
        ]
        if let top = snapshot.topLanguage {
            content.append(SectionHeaderView("Top language"))
            content.append(RankedListView(rows: [RankedRow(top.name, Format.count(top.lines), Double(top.lines),
                                                            symbol: languageSymbol(top.name),
                                                            mark: LanguageMarks.mark(for: top.name))]))
        }
        setContent(content)
    }

    private func tileRow(_ tiles: [NSView]) -> NSStackView {
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }
}

final class LanguagesTabController: DashboardTabController {
    override func apply(_ snapshot: DashboardSnapshot) {
        super.apply(snapshot)
        setContent([
            DonutChartView(languages: snapshot.languages),
            SectionHeaderView("Lines by language"),
            RankedListView(rows: snapshot.languages.map {
                RankedRow($0.name, Format.count($0.lines), Double($0.lines),
                          symbol: languageSymbol($0.name), mark: LanguageMarks.mark(for: $0.name))
            }),
        ])
    }
}

final class ModelsTabController: DashboardTabController {
    override func apply(_ snapshot: DashboardSnapshot) {
        super.apply(snapshot)
        setContent([
            RankedListView(rows: snapshot.models.map {
                // The detail line only adds information when the hero is cost.
                // In tokens mode it would just repeat the value beside it.
                RankedRow($0.label, Format.listValue($0, snapshot.metric), Format.listMagnitude($0, snapshot.metric),
                          detail: snapshot.metric == .cost ? Format.tokens($0.tokens) : nil,
                          symbol: "cpu")
            }),
        ])
    }
}

final class ProjectsTabController: DashboardTabController {
    override func apply(_ snapshot: DashboardSnapshot) {
        super.apply(snapshot)
        setContent([
            RankedListView(rows: snapshot.projects.map {
                RankedRow($0.label, Format.listValue($0, snapshot.metric), Format.listMagnitude($0, snapshot.metric),
                          symbol: "folder")
            }),
        ])
    }
}

final class UsageTabController: DashboardTabController {
    override func apply(_ snapshot: DashboardSnapshot) {
        super.apply(snapshot)
        let parts: [(label: String, tokens: Int, cost: Double, symbol: String)] = [
            ("Input", snapshot.tokens.input, snapshot.cost.input, "arrow.down.circle"),
            ("Output", snapshot.tokens.output, snapshot.cost.output, "arrow.up.circle"),
            ("Cache Read", snapshot.tokens.cacheRead, snapshot.cost.cacheRead, "bolt"),
            ("Cache Write", snapshot.tokens.cacheWrite, snapshot.cost.cacheWrite, "square.and.arrow.down"),
        ]
        let breakdown = parts.map {
            RankedRow($0.label, Format.value($0.tokens, $0.cost, snapshot.metric),
                      Format.magnitude($0.tokens, $0.cost, snapshot.metric), symbol: $0.symbol)
        }
        let tools = snapshot.tools.map { RankedRow($0.label, Format.count($0.count), Double($0.count), symbol: toolSymbol($0.label)) }
        setContent([
            SectionHeaderView("Breakdown"),
            RankedListView(rows: breakdown),
            SectionHeaderView("Tool calls"),
            RankedListView(rows: tools),
        ])
    }
}
