import XCTest
@testable import PiStatusBarKit

// The state files name projects and working directories, so the directory that
// holds them must stay closed to the other accounts on the machine.
final class AppPathsTests: XCTestCase {
    private func posixMode(_ path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let value = attrs[.posixPermissions] as? NSNumber else { return nil }
        return value.intValue
    }

    func testPrivateDirectoryIsOwnerOnly() throws {
        let root = NSTemporaryDirectory() + "apppaths-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(posixMode(root), 0o755, "the fixture starts readable by others")

        makePrivateDirectory(root)
        XCTAssertEqual(posixMode(root), 0o700, "an existing directory is closed again")

        let fresh = root + "/nested"
        makePrivateDirectory(fresh)
        XCTAssertEqual(posixMode(fresh), 0o700, "a new directory is created closed")
    }
}
