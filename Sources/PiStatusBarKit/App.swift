import Cocoa

// PiStatusBar — tiny macOS menu bar companion for the Pi coding agent.
// A Pi extension (extensions/pi-statusbar.ts) mirrors each live session into
// ~/.pi/statusbar/state.d/<sessionId>.json. This app polls that folder and
// renders one icon: spinning while any session works, a dot while one waits
// on the user, resting otherwise. It quits itself when no session is live.
//
// The app lives in the package so `swift test` can cover the parts that do
// not need a menu bar. The executable target calls PiStatusBarApp.main().

// Icon view: a layer-hosted NSView inside the status button. Swapping
// button.image 30x/sec forced a full button relayout + title re-render
// each frame (~8% CPU); here the π + arc are persistent CALayers — the
// animation only mutates arcLayer.rotation, which the GPU composites.
public enum PiStatusBarApp {
    public static func main() {
        // One instance only: a second launch wakes the running one and quits.
        if let running = runningInstancePid() {
            NSRunningApplication(processIdentifier: running)?.activate(options: [.activateAllWindows])
            exit(0)
        }

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
            // Last chance to keep the scanned work: the cache saves every few seconds.
            controller.dashboard.stop()
            // The key monitor is a global event tap: drop it on the way out.
            controller.teardown()
        }

        app.run()
    }
}

// The pid of an already running instance, if it is still alive.
private func runningInstancePid() -> Int32? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: appPidPath)) else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          SessionRules.processAlive(pid) else { return nil }
    // The file survives kill -9, and macOS reuses process numbers: only a
    // running copy of this app may claim it, or launch gives up for good.
    guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            == Bundle.main.bundleIdentifier else { return nil }
    return pid
}
