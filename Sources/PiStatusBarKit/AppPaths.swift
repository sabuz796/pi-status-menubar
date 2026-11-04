import Cocoa

// Shared color constants
let brand = NSColor.white // menu-bar white
let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // permission dot

// Single source for the state directory layout
let stateRootDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/statusbar")
let stateDir = (stateRootDir as NSString).appendingPathComponent("state.d")
let appPidPath = (stateRootDir as NSString).appendingPathComponent("app.pid")
let quitIntentPath = (stateRootDir as NSString).appendingPathComponent("quit-intent")
let sessionRootDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/sessions")
let dashboardCachePath = (stateRootDir as NSString).appendingPathComponent("dashboard-cache.json")
// Drop point when a click-to-focus command fails: the extension re-detects
// its pane ids immediately, because a failed focus usually means a stale id.
let refreshPanePath = (stateRootDir as NSString).appendingPathComponent("refresh-pane")
// One log file for the app and the extension: JSON lines, one record per event.
let logFilePath = (stateRootDir as NSString).appendingPathComponent("log.jsonl")
// Where the panel's bug button sends a report.
let issuesURL = "https://github.com/sabuz796/pi-status-menubar/issues/new"

// The state files name projects and working directories, so another account on
// the machine must not read them. createDirectory applies the mode only to a
// directory it creates, so an existing one is set again here.
func makePrivateDirectory(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
}
