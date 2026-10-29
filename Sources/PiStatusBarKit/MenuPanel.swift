import Cocoa

// The pull-down menu, presented as a popover-anchored panel: the system arrow
// exists only on popovers, so the whole menu lives in one transient NSPopover.
// Every row is a custom view — AppKit's menu highlight never reaches custom
// views — so this file owns hover, checkmarks, and key hints too.

// Full-row hover highlight shared by every panel row.
final class PanelHoverRow: NSView {
    var isHovered = false {
        didSet {
            needsDisplay = true
            hoverChanged?(isHovered)
        }
    }

    // The row hands this to whoever built it, so the text can flip to white
    // the way a native menu does. A black label on the accent fill reads as
    // "not selected".
    var hoverChanged: ((Bool) -> Void)?

    // VoiceOver reaches the row's button, which carries the action. For the
    // mouse, the row is the target too: the hover highlight covers the whole
    // row, so a click anywhere on it must do what the highlight promises.
    // Without this, only the title's own few points reacted and the new icon
    // column was dead space.
    var activate: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Act on release inside the row, like a menu item: pressing Quit and
    // dragging off must not quit.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate?() }
    }

    // Our own hover tracking area. Not tracked via trackingAreas.isEmpty: a
    // row.toolTip makes AppKit add its own internal tracking area, so the
    // session rows (the only rows with a tooltip) always passed "isNotEmpty"
    // and never got a hover area at all.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverChanged != nil else { return }
        if let area = hoverArea {
            if area.rect == bounds { return }
            removeTrackingArea(area)
            hoverArea = nil
        }
        // activeAlways, not activeInKeyWindow: the panel is deliberately
        // not key until the user clicks inside it, so key-window tracking
        // left the first hover unhighlighted.
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

// The panel is not key until something inside it is clicked, so AppKit spends
// the first click on activating the app and the row never runs its action.
// That is why Dashboard… and the toggles took two clicks.
final class PanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A row's clickable label is a real borderless button: AppKit then gives it
// the right accessibility name and value, which a plain text field does not.
// The checkmark is a separate element so it stays out of the spoken name.
private let rowFont = NSFont.menuFont(ofSize: 13)
private let rowDetailFont = NSFont.systemFont(ofSize: 11)
// Shared row grid: text starts at the same x on every row, so the check,
// symbol, and label columns line up down the whole panel.
private let contentInset: CGFloat = 14
private let rowHeight: CGFloat = 30
private let iconColumn: CGFloat = 22

// Row text, tinted for the current hover state in one place.
private func rowText(_ text: String, font: NSFont, base: NSColor, hovered: Bool) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: hovered ? hoverInk() : base,
    ])
}

// The accent fill behind a hovered row can be pale (yellow, mint), where the
// system's near-white selected text loses contrast. Black or white, whichever
// contrasts more with the accent the fill actually uses.
func hoverInk(for accent: NSColor) -> NSColor {
    guard let a = accent.usingColorSpace(.sRGB) else { return .selectedMenuItemTextColor }
    let l = 0.2126 * a.redComponent + 0.7152 * a.greenComponent + 0.0722 * a.blueComponent
    // WCAG relative contrast against white and against black.
    let againstWhite = 1.05 / (l + 0.05)
    let againstBlack = (l + 0.05) / 0.05
    return againstBlack >= againstWhite ? .black : .white
}

func hoverInk() -> NSColor { hoverInk(for: NSColor.controlAccentColor) }

private func rowButton(_ title: String, checked: Bool?) -> (mark: NSTextField, button: NSButton) {
    let mark = NSTextField(labelWithAttributedString: rowText(
        checked == true ? "✓" : " ", font: rowFont, base: .labelColor, hovered: false))
    mark.translatesAutoresizingMaskIntoConstraints = false
    mark.widthAnchor.constraint(equalToConstant: 14).isActive = true
    let b = PanelButton()
    b.isBordered = false
    b.attributedTitle = rowText(title, font: rowFont, base: .labelColor, hovered: false)
    (b.cell as? NSButtonCell)?.alignment = .left
    b.setAccessibilityLabel(title)
    return (mark, b)
}

// Leading symbol column. Template images take the tint, so one view goes grey
// to white with the rest of the row when the row is hovered.
private func rowIcon(_ symbol: String) -> NSImageView {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    let view = NSImageView(image: image ?? NSImage())
    view.translatesAutoresizingMaskIntoConstraints = false
    view.imageScaling = .scaleProportionallyDown
    view.contentTintColor = .secondaryLabelColor
    view.widthAnchor.constraint(equalToConstant: iconColumn).isActive = true
    return view
}

// The panel's own background. Painting it solid is what keeps the system
// material (glass) from showing through, and it matches the dashboard card.
final class PanelBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// Painted rather than a layer color: a CGColor copied from separatorColor
// freezes the appearance it was created in, so a light/dark switch would
// leave the hairline the wrong shade.
final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

final class MenuPanelViewController: NSViewController {
    typealias SessionRow = (glyph: String, glyphColor: NSColor, name: String, state: String, id: String,
                            terminalApp: String, terminalWindowId: String, terminalWorkspaceId: String,
                            termProgram: String)

    // Data and actions come from StatusController; the panel owns no state,
    // so every action rebuilds from current truth.
    var rows: () -> (sessions: [SessionRow], showTimer: Bool, showText: Bool,
                     permission: Bool, finish: Bool) = { ([], false, false, false, false) }
    var toggled: (String) -> Void = { _ in }
    var previewed: (Int) -> Void = { _ in }
    var focusSessionRequested: (String, String, String, String, String) -> Void = { _, _, _, _, _ in }
    var dashboardRequested: () -> Void = {}
    var reportRequested: () -> Void = {}
    var quitRequested: () -> Void = {}

    // Session status labels that tick() keeps current while the panel is open.
    private var sessionLabels: [String: (state: NSTextField, dot: NSTextField, name: NSTextField,
                                        row: PanelHoverRow)] = [:]
    // Rebuilt with the rows, so an action can never outlive the row that owns it.
    private var actionHandlers: [String: () -> Void] = [:]
    private let stack = NSStackView()

    override func loadView() {
        let container = PanelBackgroundView()
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
        actionHandlers.removeAll()
        let r = rows()

        if !r.sessions.isEmpty {
            heading("Sessions")
            for s in r.sessions { sessionRow(s) }
            stack.addArrangedSubview(divider())
        }
        heading("View")
        toggleRow("Show Timer", symbol: "clock", key: "showTimer", checked: r.showTimer)
        toggleRow("Show Text", symbol: "doc.text", key: "showLabel", checked: r.showText)
        stack.addArrangedSubview(divider())
        heading("Sounds")
        soundRow("Permission Sound", symbol: "speaker.wave.2", key: "permissionSound",
                 enabled: r.permission, tag: 0)
        soundRow("Finish Sound", symbol: "music.note", key: "doneSound",
                 enabled: r.finish, tag: 1)
        stack.addArrangedSubview(divider())
        // No key hints: the panel does not take the keyboard, so ⌘D here would
        // reach the user's app instead. A shortcut that only works once the
        // user has clicked in is not worth advertising.
        actionRow("Dashboard…", symbol: "square.grid.2x2", identifier: "dashboard",
                  requested: { [weak self] in self?.dashboardRequested() })
        stack.addArrangedSubview(divider())
        actionRow("Report a Bug", symbol: "ladybug", identifier: "bug",
                  requested: { [weak self] in self?.reportRequested() })
        stack.addArrangedSubview(divider())
        actionRow("Quit", symbol: "rectangle.portrait.and.arrow.right", identifier: "quit",
                  requested: { [weak self] in self?.quitRequested() })
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(NSView())

        // Rows are pinned to the stack's width; NSPopover sizes its frame
        // to preferredContentSize.
        preferredContentSize = NSSize(width: 320, height: stack.fittingSize.height + 14)
    }

    // The state text and the dot color move together: a dot that still reads
    // "idle" next to the words "Awaiting input" tells the user two things.
    func refreshSessions(_ sessions: [SessionRow]) {
        // Updating in place cannot add or remove a row, so a session that starts
        // or closes while the panel is open needs a rebuild.
        if Set(sessions.map { $0.id }) != Set(sessionLabels.keys) { rebuild(); return }
        for s in sessions {
            guard let labels = sessionLabels[s.id] else { continue }
            // A tick must keep the hover tint, or the text snaps back to grey
            // under the mouse.
            labels.state.attributedStringValue = rowText(
                s.state, font: rowDetailFont, base: .secondaryLabelColor, hovered: labels.row.isHovered)
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
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: 2),
        ])
        stack.addArrangedSubview(holder)
    }

    private func divider() -> NSView {
        let holder = NSView()
        let line = SeparatorView()
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            holder.heightAnchor.constraint(equalToConstant: 9),
        ])
        return holder
    }

    private func toggleRow(_ title: String, symbol: String, key: String, checked: Bool) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        let (mark, label) = rowButton(title, checked: checked)
        let icon = rowIcon(symbol)
        label.target = self
        label.action = #selector(toggleRowPressed(_:))
        label.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        label.setAccessibilityValue(checked ? "on" : "off")
        row.activate = { [weak self] in self?.toggleKey(key) }
        row.hoverChanged = { hovered in
            mark.attributedStringValue = rowText(checked ? "✓" : " ", font: rowFont,
                                                 base: .labelColor, hovered: hovered)
            label.attributedTitle = rowText(title, font: rowFont, base: .labelColor, hovered: hovered)
            icon.contentTintColor = hovered ? hoverInk() : .secondaryLabelColor
        }
        addRowToStack(row, leading: [mark, icon, label], trailing: nil)
    }

    private func soundRow(_ title: String, symbol: String, key: String, enabled: Bool, tag: Int) {
        let row = PanelHoverRow()
        let (mark, label) = rowButton(title, checked: enabled)
        let icon = rowIcon(symbol)
        label.target = self
        label.action = #selector(toggleRowPressed(_:))
        label.identifier = NSUserInterfaceItemIdentifier("toggle|\(key)")
        label.setAccessibilityValue(enabled ? "on" : "off")
        row.activate = { [weak self] in self?.toggleKey(key) }
        let play = PanelButton()
        play.isBordered = false
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play test sound")
        play.contentTintColor = .labelColor
        play.toolTip = "Play test sound"
        play.target = self
        play.action = #selector(playPressed(_:))
        play.tag = tag
        play.setAccessibilityLabel("Play \(title)")
        row.hoverChanged = { hovered in
            mark.attributedStringValue = rowText(enabled ? "✓" : " ", font: rowFont,
                                                 base: .labelColor, hovered: hovered)
            label.attributedTitle = rowText(title, font: rowFont, base: .labelColor, hovered: hovered)
            play.contentTintColor = hovered ? hoverInk() : .labelColor
            icon.contentTintColor = hovered ? hoverInk() : .secondaryLabelColor
        }
        addRowToStack(row, leading: [mark, icon, label], trailing: play)
    }

    private func sessionRow(_ s: SessionRow) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("session|\(s.id)")
        let focusable = !s.terminalWindowId.isEmpty
        if focusable {
            row.toolTip = "Focus this session in \(s.terminalApp)"
        } else if let name = terminalAppName(s.termProgram) {
            row.toolTip = "Bring \(name) to the front"
        }
        row.activate = { [weak self] in self?.focusSessionRequested(s.id,
                                                                    s.terminalApp,
                                                                    s.terminalWindowId,
                                                                    s.terminalWorkspaceId,
                                                                    s.termProgram) }

        let dot = NSTextField(labelWithAttributedString: NSAttributedString(string: s.glyph, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: s.glyphColor,
        ]))
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let name = NSTextField(labelWithAttributedString: rowText(s.name, font: rowFont, base: .labelColor, hovered: false))
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setAccessibilityValue(s.state)
        let state = NSTextField(labelWithAttributedString: NSAttributedString(
            string: s.state,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        state.translatesAutoresizingMaskIntoConstraints = false
        // Every session row hovers like the rest of the menu: the click target
        // differs (exact pane vs. raise the terminal app), never the highlight.
        row.hoverChanged = { hovered in
            name.attributedStringValue = rowText(s.name, font: rowFont, base: .labelColor, hovered: hovered)
            state.attributedStringValue = rowText(s.state, font: rowDetailFont,
                                                  base: .secondaryLabelColor, hovered: hovered)
        }
        sessionLabels[s.id] = (state, dot, name, row)
        logEvent(level: "info", source: "app", event: "row-built",
                 ["row": "session|\(s.id)", "focusable": focusable ? "1" : "0",
                  "pane": s.terminalWindowId, "app": s.terminalApp])

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
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: contentInset),
            inner.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true
    }
    private func actionRow(_ title: String, symbol: String, identifier: String,
                           requested: @escaping () -> Void) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("action|\(identifier)")
        let (mark, label) = rowButton(title, checked: nil)
        let icon = rowIcon(symbol)
        label.target = self
        label.action = #selector(actionRowPressed(_:))
        label.identifier = NSUserInterfaceItemIdentifier("action|\(identifier)")
        actionHandlers[identifier] = requested
        row.activate = requested
        row.hoverChanged = { hovered in
            label.attributedTitle = rowText(title, font: rowFont, base: .labelColor, hovered: hovered)
            icon.contentTintColor = hovered ? hoverInk() : .secondaryLabelColor
        }
        addRowToStack(row, leading: [mark, icon, label], trailing: nil)
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
            row.heightAnchor.constraint(equalToConstant: rowHeight),
            lead.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: contentInset),
            lead.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        if let trailing = trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(trailing)
            NSLayoutConstraint.activate([
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
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

    @objc private func actionRowPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.components(separatedBy: "|").last else { return }
        actionHandlers[id]?()
    }

    @objc private func playPressed(_ sender: NSButton) {
        previewed(sender.tag)
    }
}
