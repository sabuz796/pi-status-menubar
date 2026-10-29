// swift-tools-version: 5.9
import PackageDescription

// One package for the app, its logic, and its tests.
//
// PiStatusBarKit holds everything that can be reasoned about on its own:
// the session rules, the dashboard scanner, and the panel. PiStatusBar is
// the thin executable that starts the menu bar app. The split is what lets
// `swift test` cover the rules without launching a menu bar app.
let package = Package(
    name: "PiStatusBar",
    platforms: [.macOS(.v13)],
    // The extension tests and their fixtures are plain Node files, not Swift.
    targets: [
        .target(name: "PiStatusBarKit"),
        .executableTarget(name: "PiStatusBar", dependencies: ["PiStatusBarKit"]),
        // The path is lowercase to match the folder that already holds the
        // Node tests; macOS would not notice, a case-sensitive checkout would.
        .testTarget(name: "PiStatusBarKitTests", dependencies: ["PiStatusBarKit"],
                    path: "tests", exclude: ["extension.test.mjs", "fixtures"]),
    ]
)
