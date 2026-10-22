import Cocoa

// The pull-down menu, presented as a popover-anchored panel: the system arrow
// exists only on popovers, so the whole menu lives in one transient NSPopover.
// Every row is a custom view — AppKit's menu highlight never reaches custom
// views — so this file owns hover, checkmarks, and key hints too.

// Full-row hover highlight shared by every panel row.
final class PanelHoverRow: NSView {
    var isHovered = false {
        didSet { needsDisplay = true }
    }

    // VoiceOver presses the row itself, so the row carries the action.
    var activate: (() -> Void)?

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self, userInfo: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

// A row's clickable label is a real borderless button: AppKit then gives it
// the right accessibility name and value, which a plain text field does not.
// The checkmark is a separate element so it stays out of the spoken name.
private func rowButton(_ title: String, checked: Bool?) -> (mark: NSTextField, button: NSButton) {
    let mark = NSTextField(labelWithAttributedString: NSAttributedString(
        string: checked == true ? "✓" : " ",
        attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
    mark.translatesAutoresizingMaskIntoConstraints = false
    mark.widthAnchor.constraint(equalToConstant: 12).isActive = true
    let b = NSButton()
    b.isBordered = false
    b.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    (b.cell as? NSButtonCell)?.alignment = .left
    b.setAccessibilityLabel(title)
    return (mark, b)
}

final class MenuPanelViewController: NSViewController {
    typealias SessionRow = (glyph: String, glyphColor: NSColor, name: String, state: String,
                            id: String, app: String)

    // Data and actions come from StatusController; the panel owns no state,
    // so every action rebuilds from current truth.
    var rows: () -> (sessions: [SessionRow], showTimer: Bool, showText: Bool,
                     permission: Bool, finish: Bool) = { ([], false, false, false, false) }
    var toggled: (String) -> Void = { _ in }
    var previewed: (Int) -> Void = { _ in }
    var sessionOpened: (String, String) -> Void = { _, _ in }
    var dashboardRequested: () -> Void = {}
    var quitRequested: () -> Void = {}

    // Session status labels that tick() keeps current while the panel is open.
    private var sessionLabels: [String: (state: NSTextField, dot: NSTextField, name: NSButton)] = [:]
    private let stack = NSStackView()

    override func loadView() {
        let container = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            container.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 8),
        ])
        view = container
        rebuild()
    }

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sessionLabels.removeAll()
        let r = rows()

        if !r.sessions.isEmpty {
            heading("Sessions")
            for s in r.sessions { sessionRow(s) }
            stack.addArrangedSubview(divider())
        }
        heading("View")
        toggleRow("Show Timer", key: "showTimer", checked: r.showTimer)
        toggleRow("Show Text", key: "showLabel", checked: r.showText)
        stack.addArrangedSubview(divider())
        heading("Sounds")
        soundRow("Permission Sound", key: "permissionSound", enabled: r.permission, tag: 0)
        soundRow("Finish Sound", key: "doneSound", enabled: r.finish, tag: 1)
        stack.addArrangedSubview(divider())
        // No key hints: the panel does not take the keyboard, so ⌘D here would
        // reach the user's app instead. A shortcut that only works once the
        // user has clicked in is not worth advertising.
        actionRow("Dashboard…", requested: { [weak self] in self?.dashboardRequested() })
        stack.addArrangedSubview(divider())
        actionRow("Quit", requested: { [weak self] in self?.quitRequested() })
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(NSView())

        // Rows are pinned to the stack's width; NSPopover sizes its frame
        // to preferredContentSize.
        preferredContentSize = NSSize(width: 300, height: stack.fittingSize.height + 14)
    }

    // The state text and the dot color move together: a dot that still reads
    // "idle" next to the words "Awaiting input" tells the user two things.
    func refreshSessions(_ sessions: [SessionRow]) {
        for s in sessions {
            guard let labels = sessionLabels[s.id] else { continue }
            labels.state.stringValue = s.state
            labels.dot.attributedStringValue = NSAttributedString(
                string: s.glyph,
                attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: s.glyphColor])
            labels.name.setAccessibilityValue(s.state)
        }
    }

    // MARK: rows

    private func heading(_ text: String) {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.4,
        ]))
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: 2),
        ])
        stack.addArrangedSubview(holder)
    }

    private func divider() -> NSView {
        let holder = NSView()
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            holder.heightAnchor.constraint(equalToConstant: 9),
        ])
        return holder
    }

    private func toggleRow(_ title: String, key: String, checked: Bool) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        let (mark, label) = rowButton(title, checked: checked)
        label.target = self
        label.action = #selector(toggleRowPressed(_:))
        label.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        label.setAccessibilityValue(checked ? "on" : "off")
        addRowToStack(row, leading: [mark, label], trailing: nil)
    }

    private func soundRow(_ title: String, key: String, enabled: Bool, tag: Int) {
        let row = PanelHoverRow()
        let (mark, label) = rowButton(title, checked: enabled)
        label.target = self
        label.action = #selector(toggleRowPressed(_:))
        label.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        label.setAccessibilityValue(enabled ? "on" : "off")
        let play = NSButton()
        play.isBordered = false
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play test sound")
        play.contentTintColor = .labelColor
        play.toolTip = "Play test sound"
        play.target = self
        play.action = #selector(playPressed(_:))
        play.tag = tag
        play.setAccessibilityLabel("Play \(title)")
        addRowToStack(row, leading: [mark, label], trailing: play)
    }

    private func sessionRow(_ s: SessionRow) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("session|\(s.id)|\(s.app)")

        let dot = NSTextField(labelWithAttributedString: NSAttributedString(string: s.glyph, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: s.glyphColor,
        ]))
        dot.translatesAutoresizingMaskIntoConstraints = false
        let name = rowButton(s.name, checked: nil).button
        name.translatesAutoresizingMaskIntoConstraints = false
        name.target = self
        name.action = #selector(sessionPressed(_:))
        name.identifier = NSUserInterfaceItemIdentifier("session|\(s.id)|\(s.app)")
        name.setAccessibilityValue(s.state)
        let state = NSTextField(labelWithAttributedString: NSAttributedString(
            string: s.state,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        state.translatesAutoresizingMaskIntoConstraints = false
        sessionLabels[s.id] = (state, dot, name)

        let top = NSStackView(views: [dot, name])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(views: [top, state])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 1
        inner.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(inner)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22),
            inner.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true
    }
    private func actionRow(_ title: String, requested: @escaping () -> Void) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("action|\(title)")
        let label = rowButton(title, checked: nil).button
        label.target = self
        label.action = #selector(actionRowPressed(_:))
        label.identifier = NSUserInterfaceItemIdentifier("action|\(title)")
        addRowToStack(row, leading: [label], trailing: nil)
    }

    // Single-line row: label on the leading side, optional right-aligned
    // control (key hint or ▶). Join the stack BEFORE any constraint that
    // references the stack width, or Auto Layout throws "no common ancestor".
    private func addRowToStack(_ row: NSView, leading: [NSView], trailing: NSView?) {
        let lead = NSStackView(views: leading)
        lead.orientation = .horizontal
        lead.alignment = .centerY
        lead.spacing = 4
        lead.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lead)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            lead.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22),
            lead.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        if let trailing = trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(trailing)
            NSLayoutConstraint.activate([
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
                trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true
    }

    // MARK: actions
    // One path for both the mouse and VoiceOver, so the checkmark redraws
    // the same way whoever pressed it.
    private func toggleKey(_ key: String) {
        toggled(key)
        rebuild()
    }

    @objc private func toggleRowPressed(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue.components(separatedBy: "|").last else { return }
        toggleKey(key)
    }

    @objc private func sessionPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.components(separatedBy: "|") else { return }
        guard id.count > 2 else { return }
        sessionOpened(id[1], id.dropFirst(2).joined(separator: "|"))
    }

    @objc private func actionRowPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.components(separatedBy: "|").last else { return }
        if id.hasPrefix("Dashboard") { dashboardRequested(); return }
        if id == "Quit" { quitRequested() }
    }

    @objc private func playPressed(_ sender: NSButton) {
        previewed(sender.tag)
    }
}
