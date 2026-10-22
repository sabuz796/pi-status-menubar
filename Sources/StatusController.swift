import Cocoa

final class IconView: NSView {
    let piLayer = CALayer() // white-tinted pi.png glyph
    let ringLayer = CAShapeLayer() // static full ring: anchors the circle's center
    let arcLayer = CAShapeLayer() // rotating sweep on top of the ring
    let dotLayer = CAShapeLayer()
    let canvas: CGFloat = 22 // standard menu bar icon height

    // White-tinted pi.png: keep the asset's alpha as the shape, force RGB to
    // white so the glyph matches other menu bar extras and stays legible on a
    // dark bar. Premultiplied, so RGB must equal alpha, not 255.
    static func whitePi() -> CGImage? {
        guard let url = Bundle.main.url(forResource: "pi", withExtension: "png"),
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return nil }
        let p = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = p[i + 3]
            p[i] = a; p[i + 1] = a; p[i + 2] = a
        }
        return ctx.makeImage()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Transparent to clicks: the status button must get them to open the menu.
        return nil
    }

    override init(frame: NSRect) {
        // 22px canvas: glyph + arc + dot all centered on (11,11).
        // The π asset is 1.2:1 (bbox 448x374 in 512), so a 14px working
        // glyph plus an 8.6 radius ring is the largest pair that clears
        // each other; measured 0% arc/glyph overlap at these numbers.
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(piLayer)
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(arcLayer)
        layer?.addSublayer(dotLayer)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        piLayer.contents = IconView.whitePi()
        piLayer.contentsGravity = .resizeAspect
        piLayer.contentsScale = scale
        piLayer.frame = bounds
        // A lone 110° sweep reads as off-center: its visible mass sits in the
        // upper right even though the circle is concentric (measured 2.8pt
        // right / 4.3pt up of the glyph's bbox center). A faint full ring
        // anchors the center so the sweep reads as motion around the glyph.
        let full = CGMutablePath()
        full.addEllipse(in: CGRect(x: 11 - 8.6, y: 11 - 8.6, width: 17.2, height: 17.2))
        ringLayer.path = full
        ringLayer.strokeColor = brand.withAlphaComponent(0.3).cgColor
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 1.7
        ringLayer.frame = bounds
        ringLayer.contentsScale = scale
        ringLayer.isHidden = true
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: 11, y: 11), radius: 8.6,
                   startAngle: 0, endAngle: 110 * CGFloat.pi / 180, clockwise: false)
        arcLayer.path = arc
        arcLayer.strokeColor = brand.cgColor
        arcLayer.fillColor = nil
        arcLayer.lineWidth = 1.7
        arcLayer.lineCap = .round
        arcLayer.frame = bounds
        arcLayer.contentsScale = scale
        arcLayer.isHidden = true
        dotLayer.fillColor = amber.cgColor
        dotLayer.contentsScale = scale
        dotLayer.frame = bounds
        dotLayer.isHidden = true
        show(mode: "idle")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setGlyph(size: CGFloat, opacity: Float) {
        piLayer.frame = CGRect(x: (canvas - size) / 2, y: (canvas - size) / 2, width: size, height: size)
        piLayer.opacity = opacity
    }

    // mode: idle | working(angle, alpha) | permission(scale)
    func show(mode: String, angle: CGFloat = 0, alpha: CGFloat = 1, dotScale: CGFloat = 1) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case "working":
            setGlyph(size: 14, opacity: Float(0.95 * alpha))
            ringLayer.isHidden = false
            ringLayer.opacity = Float(alpha)
            arcLayer.isHidden = false
            arcLayer.opacity = Float(alpha)
            // CALayer rotates about its anchor point (the layer center, which
            // is the ring center), so no manual translate is needed. Adding one
            // shifted the sweep off the ring as it turned (measured: arc drifted
            // to radius 2.5-12.0pt at 45deg instead of holding 7.75-9.45pt).
            arcLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            dotLayer.isHidden = true
        case "permission":
            setGlyph(size: 14, opacity: 0)
            ringLayer.isHidden = true
            arcLayer.isHidden = true
            dotLayer.isHidden = false
            let d = 10 * dotScale
            dotLayer.path = CGPath(ellipseIn: CGRect(x: 11 - d / 2, y: 11 - d / 2, width: d, height: d), transform: nil)
        default:
            setGlyph(size: 18.5, opacity: Float(0.92 * alpha))
            ringLayer.isHidden = true
            arcLayer.isHidden = true
            dotLayer.isHidden = true
        }
        CATransaction.commit()
    }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    lazy var iconView: IconView = {
        let v = IconView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        guard let button = statusItem.button else { return v }
        // Transparent placeholder reserves the 22px image slot in the
        // button layout; the live layers draw over it. Title flows right.
        button.image = NSImage(size: NSSize(width: 22, height: 22))
        button.imagePosition = .imageLeading
        button.addSubview(v)
        return v
    }()
    // Pin the overlay onto the image slot the button actually reserves.
    // Pinning at x:0 left the icon sitting a few px left of the text, because
    // NSButton insets its content and centers image + title as a group.
    func layoutIcon() {
        guard let button = statusItem.button else { return }
        let size = iconView.canvas
        var slot = NSRect(x: 0, y: round((button.bounds.height - size) / 2), width: size, height: size)
        if let cell = button.cell as? NSButtonCell {
            let rect = cell.imageRect(forBounds: button.bounds)
            if rect.width > 0.5 && rect.width < button.bounds.width {
                slot.origin.x = round(rect.midX - size / 2)
            }
        }
        iconView.frame = slot
    }

    // Staleness caps - aligned with extension's heartbeat refresh
    let workingStaleCap: TimeInterval = 180 // 3 missed heartbeats (30s each)
    let permissionStaleCap: TimeInterval = 7200 // 2 hours
    let idleReapAfter: TimeInterval = 900 // 15 minutes for dead sessions

    var pollTimer: Timer?
    // 30fps animation timer driving layer transforms only (no image swaps,
    // so no button relayout per frame). Idles at zero: the timer stops in
    // idle/permission-settled states.
    var animTimer: Timer?
    var visualMode = "idle" // idle | working | permission
    var modeEnteredAt = Date()
    let popDuration = 0.2 // soft scale pop when a mode is entered

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5
    let idleQuitDelay: TimeInterval = 3

    struct Session {
        var id: String
        var state: String
        var label: String
        var project: String
        var cwd: String
        var sessionName: String
        var termProgram: String
        var pid: Int32
        var started: Bool
        var startedAt: Double
        var ts: Double
        var eff: String = ""

        init(json o: [String: Any], id: String) {
            self.id = id
            self.state = o["state"] as? String ?? "idle"
            self.label = o["label"] as? String ?? ""
            self.project = o["project"] as? String ?? ""
            self.cwd = o["cwd"] as? String ?? ""
            self.sessionName = o["sessionName"] as? String ?? ""
            self.termProgram = o["term_program"] as? String ?? ""
            self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
            self.started = o["started"] as? Bool ?? true
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
        }
    }

    var sessions: [String: Session] = [:]
    var fileMTimes: [String: Date] = [:]
    var panelPopover: NSPopover?
    var keyMonitor: Any?
    private(set) lazy var menuPanel: MenuPanelViewController = {
        let vc = MenuPanelViewController()
        vc.rows = { [weak self] in
            guard let self else { return ([], false, false, false, false) }
            return (self.panelSessions(), self.showTimer, self.showLabel,
                    self.cues.permissionEnabled, self.cues.doneEnabled)
        }
        vc.toggled = { [weak self] key in self?.toggleByKey(key) }
        vc.previewed = { [weak self] tag in
            self?.cues.preview(tag == 0 ? .permission : .done)
        }
        vc.sessionOpened = { [weak self] id, app in self?.openSession(id: id, app: app) }
        vc.dashboardRequested = { [weak self] in self?.swapToDashboard() }
        vc.quitRequested = { [weak self] in self?.quit() }
        return vc
    }()


    var activeBase = ""
    var startedAt: Double = 0
    var lastTitleText: String? = nil
    let dashboard: DashboardStore
    var dashboardPopover: DashboardPopoverController?

    // Working spinner: thin arc orbiting the π, one revolution per cycle.
    let arcPeriod = 1.1 // seconds per revolution
    var showTimer = true
    var showLabel = true
    let cues = CuePlayer()
    // Last effective state per session, tracked outside Session because a state
    // file rewrite replaces the Session struct and would reset its stored state.
    var lastEff: [String: String] = [:]

    override init() {
        dashboard = DashboardStore(cachePath: dashboardCachePath, sessionRoot: sessionRootDir)
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "showLabel") != nil { showLabel = d.bool(forKey: "showLabel") }
        if d.object(forKey: "permissionSound") != nil { cues.permissionEnabled = d.bool(forKey: "permissionSound") }
        if d.object(forKey: "doneSound") != nil { cues.doneEnabled = d.bool(forKey: "doneSound") }
        // Write PID file for extension's appRunning() check
        try? FileManager.default.createDirectory(atPath: stateRootDir, withIntermediateDirectories: true)
        try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: appPidPath, atomically: true, encoding: .utf8)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        _ = iconView
        iconView.show(mode: "idle")
        render(label: "", animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        startKeyMonitor()
        // A new launch voids a prior explicit Quit.
        try? FileManager.default.removeItem(atPath: quitIntentPath)
        ensureExtensionInstalled()
        // Warm the dashboard cache in the background so the first open renders
        // real numbers instead of the empty snapshot.
        dashboard.refresh()
    }

    // MARK: extension install

    // First launch (and every version change): copy the bundled extension into
    // ~/.pi/agent/extensions/ so Pi loads it. Never touches other config.
    // The bundle wins on a version change, so shipped fixes always land.
    func ensureExtensionInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedVersion") != current,
              let src = Bundle.main.path(forResource: "pi-statusbar", ofType: "ts") else { return }
        let destDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/extensions")
        let dest = (destDir as NSString).appendingPathComponent("pi-statusbar.ts")
        do {
            try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest) {
                let destData = try Data(contentsOf: URL(fileURLWithPath: dest))
                let srcData = try Data(contentsOf: URL(fileURLWithPath: src))
                if destData == srcData {
                    d.set(current, forKey: "installedVersion")
                    return
                }
                try? FileManager.default.removeItem(atPath: dest)
            }
            try FileManager.default.copyItem(atPath: src, toPath: dest)
            d.set(current, forKey: "installedVersion")
        } catch {
            NSLog("PiStatusBar: extension install failed: \(error)")
        }
    }

    // MARK: polling

    func tick() {
        reloadSessions()
        evaluate()
        checkLifecycle()
        if panelPopover?.isShown == true { menuPanel.refreshSessions(panelSessions()) }
    }

    func stateFileNames() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else {
            NSLog("PiStatusBar: cannot read state directory")
            return []
        }
        return files.filter { $0.hasSuffix(".json") }
    }

    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFileNames()
        let present = Set(files)
        for key in Array(fileMTimes.keys) where !present.contains(key) {
            fileMTimes[key] = nil
            sessions[(key as NSString).deletingPathExtension] = nil
        }
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if fileMTimes[f] == m { continue }
            fileMTimes[f] = m
            guard let data = fm.contents(atPath: full) else {
                NSLog("PiStatusBar: cannot read state file \(f)")
                continue
            }
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("PiStatusBar: cannot parse state file \(f)")
                continue
            }
            sessions[(f as NSString).deletingPathExtension] = Session(json: o, id: (f as NSString).deletingPathExtension)
        }
    }

    func priority(of eff: String) -> Int {
        switch eff {
        case "permission": return 2
        case "thinking", "tool": return 1
        default: return 0
        }
    }

    func effectiveState(_ s: Session, now: Double) -> String {
        if s.state == "thinking" || s.state == "tool" || s.state == "permission" {
            // Working states heartbeat every 30s, so ~3 missed beats means the
            // session is stuck or its writer died. Permission has no heartbeat
            // (waiting on the user can legitimately last hours).
            let cap: Double = s.state == "permission" ? permissionStaleCap : workingStaleCap
            if now - s.ts > cap { return "idle" }
            return s.state
        }
        return s.state == "done" ? "idle" : s.state
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            let previous = lastEff[id]
            s.eff = effectiveState(s, now: now)
            // Reap on process death: kill(pid,0). An idle file older than
            // idleReapAfter is reaped too, so a reused PID cannot pin it, and
            // files with no pid fall back to the same age prune.
            let staleIdle = s.eff == "idle" && now - s.ts > idleReapAfter
            let dead = staleIdle || (s.pid > 0 && !pidAlive(s.pid))
            if dead {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                sessions[id] = nil
                fileMTimes[id + ".json"] = nil
                lastEff[id] = nil
                continue
            }
            lastEff[id] = s.eff
            // The rules for what deserves a sound live in CuePlayer.cue, where
            // they are covered by tests/cues.
            if let cue = CuePlayer.cue(from: previous, to: s.eff) { cues.play(cue) }
            sessions[id] = s
        }
        let lead = sessions.values.max { a, b in
            let pa = priority(of: a.eff), pb = priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        statusItem.button?.toolTip = lead.map { s in
            let p = sessionParts(s)
            return "\(p.glyph) \(p.name) — \(p.sub)"
        }
        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: showLabel ? lead.label : "", animate: false, startedAt: 0, dot: true)
        case "thinking", "tool":
            let text = showLabel ? (lead.label.isEmpty ? "Working…" : lead.label) : ""
            render(label: text, animate: true, startedAt: lead.startedAt)
        default:
            renderResting()
        }
    }

    func renderResting() { render(label: "", animate: false, startedAt: 0) }

    func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        // An open dashboard pins the app: never quit out from under it.
        if dashboardPopover?.isShown == true {
            notNeededSince = nil
            return
        }
        // Any session file means a Pi process is still around. Truly stale
        // files are already reaped in evaluate(), so idle sessions keep the
        // app alive instead of relaunching it on every turn.
        if !sessions.isEmpty {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // MARK: render

    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func render(label: String, animate: Bool, startedAt: Double, dot: Bool = false) {
        activeBase = label
        self.startedAt = startedAt
        let newMode = animate ? "working" : (dot ? "permission" : "idle")
        if reducedMotion {
            stopLink()
            visualMode = newMode
            modeEnteredAt = Date()
            iconView.show(mode: newMode == "working" ? "idle" : newMode)
            applyTitle()
            return
        }
        if newMode != visualMode {
            modeEnteredAt = Date()
            visualMode = newMode
            startLink()
            // Soft pop on entry: scale the whole icon view briefly.
            iconView.layer?.removeAnimation(forKey: "pop")
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.85
            pop.toValue = 1.0
            pop.duration = popDuration
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconView.layer?.add(pop, forKey: "pop")
        } else if newMode == "idle" && animTimer == nil {
            iconView.show(mode: "idle")
        }
        layoutIcon()
        applyTitle()
    }

    // MARK: display link

    func startLink() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.drawFrame() }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    func stopLink() {
        animTimer?.invalidate()
        animTimer = nil
    }

    func drawFrame() {
        let now = Date()
        let t = now.timeIntervalSince(modeEnteredAt)
        switch visualMode {
        case "working":
            // Angle from the wall clock: a slow frame never stutters.
            iconView.show(mode: "working", angle: CGFloat(2 * Double.pi) * CGFloat(t / arcPeriod), alpha: 1)
        case "permission":
            // Gentle pulse while waiting; pop handled by the entry animation.
            iconView.show(mode: "permission", dotScale: 1 + 0.12 * CGFloat(sin(2 * Double.pi * 2 * t)))
        default:
            iconView.show(mode: "idle")
            stopLink()
        }
        layoutIcon()
        applyTitle()
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = activeBase
        if showTimer, startedAt > 0 {
            let clock = elapsed(max(0, Int(Date().timeIntervalSince1970 - startedAt)))
            text = text.isEmpty ? clock : text + "  " + clock
        }
        guard text != lastTitleText else { return }
        lastTitleText = text
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

// MARK: dashboard popover

    func showDashboardPopover() {
        guard let button = statusItem.button else { return }
        if dashboardPopover == nil { dashboardPopover = DashboardPopoverController(store: dashboard) }
        dashboardPopover?.show(relativeTo: button)
    }

    // Sonoma-style state parts: colored glyph + name + one-line status text.
    func sessionParts(_ s: Session, eff: String? = nil) -> (glyph: String, name: String, sub: String, color: NSColor) {
        let now = Date().timeIntervalSince1970
        let e = eff ?? (s.eff.isEmpty ? effectiveState(s, now: now) : s.eff)
        // Pi's own session name is what distinguishes two sessions in the
        // same project; fall back to the project folder when it is empty.
        let name = !s.sessionName.isEmpty ? s.sessionName
                   : (s.project.isEmpty ? "session" : s.project)
        switch e {
        case "permission":
            return ("●", name, "Awaiting input", NSColor.systemRed)
        case "thinking", "tool":
            var sub = s.label.isEmpty ? "Working" : s.label
            if s.startedAt > 0 { sub += " · " + elapsed(max(0, Int(now - s.startedAt))) }
            return ("◐", name, sub, NSColor.systemBlue)
        default:
            return ("○", name, "Idle", NSColor.systemGray)
        }
    }

    @objc func quit() {
        FileManager.default.createFile(atPath: quitIntentPath, contents: nil)
        NSApp.terminate(nil)
    }

    func openSession(id: String, app: String) {
        guard !app.isEmpty else { return }
        let name: String
        switch app {
        case "Apple_Terminal": name = "Terminal"
        case "iTerm.app": name = "iTerm"
        case "vscode": name = "Visual Studio Code"
        case "WarpTerminal": name = "Warp"
        default: name = app
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        try? p.run()
    }
}

