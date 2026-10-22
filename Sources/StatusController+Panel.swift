import Cocoa

// Panel mode: everything that opens, closes, feeds, and quits through the
// π popover panel. Key paths live here too, because the panel is not an
// NSMenu, so AppKit dispatches no keyboard equivalents for it.
extension StatusController {
    @objc func togglePanel() {
        guard let button = statusItem.button else { return }
        if let shown = panelPopover, shown.isShown {
            shown.performClose(nil)
            return
        }
        // An accessory app resigns active when tracking stops; same trick the
        // Dashboard popover already uses, or the panel would flicker away.
        NSApp.activate(ignoringOtherApps: true)
        menuPanel.rebuild()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = menuPanel
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panelPopover = p
    }

    var panelIsOpen: Bool { panelPopover?.isShown == true }

    func closePanel() {
        panelPopover?.performClose(nil)
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

    // App-level keyboard paths the panel cannot get from an NSMenu:
    // Escape closes the panel, ⌘D opens the Dashboard, ⌘Q quits.
    // A local monitor hears keys only while the app is active, which for an
    // accessory app means right after it was activated; that is the state the
    // panel and its tips assume anyway.
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
    }
}
