import Cocoa

// Shared serial queue for focusing a multiplexer pane. Module-level because an
// extension cannot add stored static properties.
private let focusQueueShared = DispatchQueue(label: "com.local.pistatusbar.focus", qos: .userInitiated)

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
            return (p.glyph, p.color, p.name, p.sub, s.id,
                    s.terminalApp, s.terminalWindowId, s.terminalWorkspaceId, s.termProgram)
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
    // Focus the session's terminal. A pane id (cmux, tmux) is exact: it runs
    // the multiplexer's own focus command for that pane. Without one the only
    // reachable target is the terminal app itself, raised to the front —
    // best effort, still far better than a dead row.
    func focusSession(id: String, app: String, pane: String, workspace: String, termProgram: String) {
        focusQueue.async {
            if pane.isEmpty || app.isEmpty {
                if let name = terminalAppName(termProgram) { _ = Self.runCLI(["open", "-a", name]) }
                return
            }
            var failed = false
            switch app {
            case "cmux":
                var args = ["cmux", "focus-pane", "--pane", pane]
                if !workspace.isEmpty { args += ["--workspace", workspace] }
                failed = Self.runCLILogged(args) != 0
            case "tmux":
                failed = Self.runCLILogged(["tmux", "select-window", "-t", pane]) != 0
                if !failed { _ = Self.runCLI(["tmux", "select-pane", "-t", pane]) }
            default:
                return
            }
            if failed {
                // A nonzero exit means the pane id is probably stale (pane
                // closed or moved). The marker names the session, so the Pi
                // process that owns it re-detects immediately.
                let marker: [String: Any] = ["sessionId": id,
                                             "ts": Int(Date().timeIntervalSince1970)]
                try? JSONSerialization.data(withJSONObject: marker)
                    .write(to: URL(fileURLWithPath: refreshPanePath))
            }
        }
    }

    // Runs a CLI and logs command + exit, so a silent focus failure in the
    // field (a GUI PATH, a stale pane id) leaves evidence in log.jsonl.
    private static func runCLILogged(_ args: [String]) -> Int32 {
        let status = runCLI(args)
        logEvent(level: "info", source: "app", event: "focus-cli",
                 ["cmd": args.joined(separator: " "), "exit": String(status)])
        return status
    }

    // Runs the CLI and waits, with the shared 2 s timeout. Returns the exit
    // status, or -1 when the tool could not be launched or ran too long.
    private static func runCLI(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        // A GUI-launched app inherits launchd's minimal PATH (/usr/bin, /bin, …),
        // so `env cmux` never finds /opt/homebrew/bin/cmux and focus fails
        // silently. Front-load the standard CLI homes; tools elsewhere on the
        // user's PATH stay out of reach (rare, self-built binaries).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return -1
        }
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + 2) == .timedOut {
            p.terminate()
            return -1
        }
        return p.terminationStatus
    }

    // Serializes focus calls so rapid clicks do not interleave.
    private var focusQueue: DispatchQueue { focusQueueShared }
}
