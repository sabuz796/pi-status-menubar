import Cocoa

// PiStatusBar — tiny macOS menu bar companion for the Pi coding agent.
// A Pi extension (extensions/pi-statusbar.ts) mirrors each live session into
// ~/.pi/statusbar/state.d/<sessionId>.json. This app polls that folder and
// renders one icon: spinning while any session works, a dot while one waits
// on the user, resting otherwise. It quits itself when no session is live.

// Shared color constants
let brand = NSColor.white // menu-bar white

// Single source for the state directory layout
let stateRootDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/statusbar")
let stateDir = (stateRootDir as NSString).appendingPathComponent("state.d")
let appPidPath = (stateRootDir as NSString).appendingPathComponent("app.pid")
let quitIntentPath = (stateRootDir as NSString).appendingPathComponent("quit-intent")
let sessionRootDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/sessions")
let dashboardCachePath = (stateRootDir as NSString).appendingPathComponent("dashboard-cache.json")
// Where the panel's bug button sends a report.
let issuesURL = "https://github.com/sabuz796/pi-status-menubar/issues/new"

if CommandLine.arguments.contains("--selfcheck") {
    // A fresh cache path keeps the check a true cold scan and leaves the real one alone.
    let selfCheckCache = (NSTemporaryDirectory() as NSString).appendingPathComponent("pi-statusbar-selfcheck.json")
    try? FileManager.default.removeItem(atPath: selfCheckCache)
    exit(SelfCheck.run(sessionRoot: sessionRootDir, cachePath: selfCheckCache))
}
// One instance only: a second launch wakes the running one and quits.
if let running = runningInstancePid() {
    NSRunningApplication(processIdentifier: running)?.activate(options: [.activateAllWindows])
    exit(0)
}

let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // permission dot

// Icon view: a layer-hosted NSView inside the status button. Swapping
// button.image 30x/sec forced a full button relayout + title re-render
// each frame (~8% CPU); here the π + arc are persistent CALayers — the
// animation only mutates arcLayer.rotation, which the GPU composites.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()

// Register for termination notifications to clean up PID file
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    // Clean up PID file on exit
    try? FileManager.default.removeItem(atPath: appPidPath)
    // The key monitor is a global event tap: drop it on the way out.
    controller.teardown()
}

app.run()

// The pid of an already running instance, if it is still alive.
func runningInstancePid() -> Int32? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: appPidPath)) else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          SessionRules.processAlive(pid) else { return nil }
    return pid
}
