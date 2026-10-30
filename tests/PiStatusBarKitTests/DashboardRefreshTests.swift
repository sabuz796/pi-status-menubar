import XCTest
@testable import PiStatusBarKit

// A refresh that lands while a pass is already running must still call its
// completion. The dashboard ends its progress spinner from that completion,
// so losing it leaves the Refresh button hidden and the spinner turning
// forever.
final class DashboardRefreshTests: XCTestCase {
    private var cachePath = ""
    private var root = ""

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "pistatusbar-refresh-\(UUID().uuidString)"
        cachePath = base + "/cache.json"
        root = base + "/sessions"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (cachePath as NSString).deletingLastPathComponent)
    }

    // Both calls happen on this thread, and the first sets its in-flight flag
    // before dispatching, so the second is always the one that used to be
    // dropped. That makes the case deterministic, not a race.
    func testAQueuedRefreshStillCallsItsCompletion() {
        let store = DashboardStore(cachePath: cachePath, sessionRoot: root)
        let first = expectation(description: "first completion")
        let queued = expectation(description: "completion of the refresh that arrived mid-pass")

        store.refresh { _ in first.fulfill() }
        store.refresh { _ in queued.fulfill() }

        wait(for: [first, queued], timeout: 10)
    }
}
