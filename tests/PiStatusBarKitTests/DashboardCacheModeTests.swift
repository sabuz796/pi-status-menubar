import XCTest
@testable import PiStatusBarKit

// The statusbar root holds private session data. If it disappears while the
// app runs (user cleanup, not a bug), the dashboard cache save must recreate
// it with the same 0700 isolation AppPaths.makePrivateDirectory enforces
// everywhere else, instead of letting the umask decide.
final class DashboardCacheModeTests: XCTestCase {
    private var base = ""
    private var cachePath = ""
    private var root = ""

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "pistatusbar-cachemode-\(UUID().uuidString)"
        cachePath = base + "/pi/statusbar/cache.json"
        root = base + "/sessions"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testSaveRecreatesTheStateRootOwnerOnly() throws {
        let store = DashboardStore(cachePath: cachePath, sessionRoot: root)
        store.saveNow() // warms the store and writes a first cache

        let statusRoot = (cachePath as NSString).deletingLastPathComponent
        try FileManager.default.removeItem(atPath: statusRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusRoot), "fixture: the root is gone")

        store.saveNow()
        let attrs = try FileManager.default.attributesOfItem(atPath: statusRoot)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o700, "a runtime-recreated status root is created owner-only, not at the umask default")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath), "the cache write still lands after the recreation")
    }
}
