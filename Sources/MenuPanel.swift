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

// NSClickGestureRecognizer subclass that carries its row action.
final class PanelActionGesture: NSClickGestureRecognizer {
    var run: () -> Void = {}
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
    private var stateLabels: [String: NSTextField] = [:]
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
        stateLabels.removeAll()
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
        actionRow("Dashboard…", hint: "⌘D", requested: { [weak self] in self?.dashboardRequested() })
        stack.addArrangedSubview(divider())
        actionRow("Quit", hint: "⌘Q", requested: { [weak self] in self?.quitRequested() })
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(NSView())

        // Rows are pinned to the stack's width; NSPopover sizes its frame
        // to preferredContentSize.
        preferredContentSize = NSSize(width: 300, height: stack.fittingSize.height + 14)
    }

    func refreshSessions(_ sessions: [SessionRow]) {
        for s in sessions {
            stateLabels[s.id]?.stringValue = s.state
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
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: (checked ? "✓ " : "   ") + title,
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        addRowToStack(row, label, trailing: nil)
        makeRowClickable(row)
    }

    private func soundRow(_ title: String, key: String, enabled: Bool, tag: Int) {
        let row = PanelHoverRow()
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: (enabled ? "✓ " : "   ") + title,
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        let play = NSButton()
        play.isBordered = false
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play test sound")
        play.contentTintColor = .labelColor
        play.toolTip = "Play test sound"
        play.target = self
        play.action = #selector(playPressed(_:))
        play.tag = tag
        addRowToStack(row, label, trailing: play)
        // The trailing ▶ is its own control, so the toggle lives on the label.
        label.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        makeRowClickable(label)
    }

    private func sessionRow(_ s: SessionRow) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("session|\(s.id)|\(s.app)")

        let dot = NSTextField(labelWithAttributedString: NSAttributedString(string: s.glyph, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: s.glyphColor,
        ]))
        dot.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithAttributedString: NSAttributedString(string: s.name, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ]))
        name.translatesAutoresizingMaskIntoConstraints = false
        let state = NSTextField(labelWithAttributedString: NSAttributedString(
            string: s.state,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        state.translatesAutoresizingMaskIntoConstraints = false
        stateLabels[s.id] = state

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
        makeRowClickable(row)
    }

    private func actionRow(_ title: String, hint: String, requested: @escaping () -> Void) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("action|\(title)")
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: title, attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        let hintLabel = NSTextField(labelWithAttributedString: NSAttributedString(
            string: hint, attributes: [.font: NSFont.menuFont(ofSize: 13),
                                       .foregroundColor: NSColor.secondaryLabelColor]))
        let gesture = PanelActionGesture(target: self, action: #selector(actionClicked(_:)))
        gesture.run = requested
        row.addGestureRecognizer(gesture)
        addRowToStack(row, label, trailing: hintLabel)
    }

    // Single-line row: label on the leading side, optional right-aligned
    // control (key hint or ▶). Join the stack BEFORE any constraint that
    // references the stack width, or Auto Layout throws "no common ancestor".
    private func addRowToStack(_ row: NSView, _ label: NSTextField, trailing: NSView?) {
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
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

    private func makeRowClickable(_ view: NSView) {
        view.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
    }

    // MARK: actions

    @objc private func rowClicked(_ gr: NSClickGestureRecognizer) {
        guard let id = gr.view?.identifier?.rawValue else { return }
        let parts = id.components(separatedBy: "|")
        switch parts.first {
        case "toggle": if parts.count > 1 { toggled(parts[1]) }
        case "session": if parts.count > 2 {
            sessionOpened(parts[1], parts.dropFirst(2).joined(separator: "|"))
        }
        default: break
        }
        rebuild()
    }

    @objc private func actionClicked(_ gr: NSClickGestureRecognizer) {
        (gr as? PanelActionGesture)?.run()
    }

    @objc private func playPressed(_ sender: NSButton) {
        previewed(sender.tag)
    }
}
