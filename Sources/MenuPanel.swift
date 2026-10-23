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
            // activeAlways, not activeInKeyWindow: the panel is deliberately
            // not key until the user clicks inside it, so key-window tracking
            // left the first hover unhighlighted.
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self, userInfo: nil))
        }
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
        .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : base,
    ])
}

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
    var reportRequested: () -> Void = {}
    var quitRequested: () -> Void = {}

    // Session status labels that tick() keeps current while the panel is open.
    private var sessionLabels: [String: (state: NSTextField, dot: NSTextField, name: NSButton,
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
        row.hoverChanged = { hovered in
            mark.attributedStringValue = rowText(checked ? "✓" : " ", font: rowFont,
                                                 base: .labelColor, hovered: hovered)
            label.attributedTitle = rowText(title, font: rowFont, base: .labelColor, hovered: hovered)
            icon.contentTintColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
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
            play.contentTintColor = hovered ? .selectedMenuItemTextColor : .labelColor
            icon.contentTintColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
        }
        addRowToStack(row, leading: [mark, icon, label], trailing: play)
    }

    private func sessionRow(_ s: SessionRow) {
        let row = PanelHoverRow()
        row.identifier = NSUserInterfaceItemIdentifier("session|\(s.id)|\(s.app)")

        let dot = NSTextField(labelWithAttributedString: NSAttributedString(string: s.glyph, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: s.glyphColor,
        ]))
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
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
        sessionLabels[s.id] = (state, dot, name, row)
        row.hoverChanged = { hovered in
            name.attributedTitle = rowText(s.name, font: rowFont, base: .labelColor, hovered: hovered)
            state.attributedStringValue = rowText(s.state, font: rowDetailFont,
                                                  base: .secondaryLabelColor, hovered: hovered)
        }

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
        row.hoverChanged = { hovered in
            label.attributedTitle = rowText(title, font: rowFont, base: .labelColor, hovered: hovered)
            icon.contentTintColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
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

    @objc private func sessionPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.components(separatedBy: "|") else { return }
        guard id.count > 2 else { return }
        sessionOpened(id[1], id.dropFirst(2).joined(separator: "|"))
    }

    @objc private func actionRowPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.components(separatedBy: "|").last else { return }
        actionHandlers[id]?()
    }

    @objc private func playPressed(_ sender: NSButton) {
        previewed(sender.tag)
    }
}
