import XCTest
@testable import PiStatusBarKit

// Literal checks on the merged icon table: the display names the dashboard
// produces must each keep their symbol and asset, and unknowns get "doc".
final class LanguageMarksTests: XCTestCase {
    func testSymbolsForDisplayNames() {
        XCTAssertEqual(LanguageMarks.symbol(for: "Swift"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(LanguageMarks.symbol(for: "SQL"), "cylinder")
        XCTAssertEqual(LanguageMarks.symbol(for: "Text"), "doc.plaintext")
        XCTAssertEqual(LanguageMarks.symbol(for: "JSON"), "curlybraces")
        XCTAssertEqual(LanguageMarks.symbol(for: "YAML"), "list.bullet.rectangle")
    }

    func testUnknownLanguageFallsBackToDoc() {
        XCTAssertEqual(LanguageMarks.symbol(for: "Brainfuck"), "doc")
    }

    func testMarkAssets() {
        XCTAssertEqual(LanguageMarks.mark(for: "Swift")?.asset, "swift")
        // No bundled SVG for these two: no mark, the symbol carries the row.
        XCTAssertNil(LanguageMarks.mark(for: "SQL"))
        XCTAssertNil(LanguageMarks.mark(for: "Text"))
        XCTAssertNil(LanguageMarks.mark(for: "Brainfuck"))
    }
}
