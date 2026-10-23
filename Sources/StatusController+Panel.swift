import Cocoa

// Panel mode: everything that opens, closes, feeds, and quits through the
// π popover panel. Key paths live here too, because the panel is not an
// NSMenu, so AppKit dispatches no keyboard equivalents for it.
extension StatusController {
    @objc func togglePanel() {
        guard let button = statusItem.button else { return }
        if let shown = panelPopover, shown.isShown {
            closePanel()
            return
        }
        // The panel does not take the keyboard: activating the app here would
        // swallow the keystrokes of whatever the user was typing in. The
        // popover shows and stays shown without being key (measured), and a
        // click inside it activates the app, which is when the key monitor
        // below starts working.
        menuPanel.rebuild()
        let p = NSPopover()
        // The popover's default appearance is the vibrant material (glass).
        // The standard system look is what we want: solid, and following the
        // machine's light or dark setting.
        p.appearance = NSApp.effectiveAppearance
        p.behavior = .transient
        p.contentViewController = menuPanel
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panelPopover = p
        startOutsideClickMonitor()
    }

    var panelIsOpen: Bool { panelPopover?.isShown == true }

    func closePanel() {
        stopOutsideClickMonitor()
        panelPopover?.performClose(nil)
    }

    // The status item's frame in screen coordinates, so a click on the π reads
    // as a toggle and not as an outside click.
    private var statusButtonFrame: NSRect {
        guard let b = statusItem.button, let w = b.window else { return .zero }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    // A transient popover normally closes on an outside click, but this panel is
    // never key and the app is never active, so AppKit does not see those clicks
    // and the panel stayed up. A global monitor does see them.
    func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            guard let p = self.panelPopover, p.isShown else { self.stopOutsideClickMonitor(); return }
            let click = NSEvent.mouseLocation
            if p.contentViewController?.view.window?.frame.contains(click) != true,
               !self.statusButtonFrame.contains(click) {
                self.closePanel()
            }
        }
    }

    func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    func panelSessions() -> [MenuPanelViewController.SessionRow] {
        return sessions.values.sorted { $0.ts > $1.ts }.filter { $0.started }.map { s in
            let p = sessionParts(s)
            return (p.glyph, p.color, p.name, p.sub, s.id, s.termProgram)
        }
    }

    func swapToDashboard() {
        closePanel()
        // The close has to land before the dashboard opens, or two popovers
        // fight over the same anchor view.
        DispatchQueue.main.async { [weak self] in self?.showDashboardPopover() }
    }

    func toggleByKey(_ key: String) {
        let on: Bool
        switch key {
        case "showTimer":
            showTimer.toggle()
            on = showTimer
        case "showLabel":
            showLabel.toggle()
            on = showLabel
        case "permissionSound":
            cues.permissionEnabled.toggle()
            on = cues.permissionEnabled
        case "doneSound":
            cues.doneEnabled.toggle()
            on = cues.doneEnabled
        default:
            return
        }
        UserDefaults.standard.set(on, forKey: key)
        // Sound choices play back so they are audible without waiting for a
        // turn; turning a cue off is silent, matching the native-menu days.
        switch key {
        case "permissionSound": if on { cues.play(.permission) }
        case "doneSound": if on { cues.play(.done) }
        default: break
        }
        evaluate()
    }

    // App-level keyboard paths, usable once the app is active (after a click
    // inside the panel). A local monitor only hears events the app receives,
    // so these do not fire while another app has the keyboard.
    func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.panelIsOpen {
                self.closePanel()
                return nil
            }
            if event.modifierFlags.contains(.command),
               let ch = event.charactersIgnoringModifiers?.lowercased() {
                switch ch {
                case "d":
                    self.swapToDashboard()
                    return nil
                case "q":
                    self.quit()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    func teardown() {
        stopKeyMonitor()
        stopOutsideClickMonitor()
    }
}
