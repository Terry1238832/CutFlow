import XCTest
@testable import CutFlow

final class FinderDimOverlayTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/CutFlow-check/source", isDirectory: true)
    private var alpha: URL { directory.appendingPathComponent("alpha.txt") }
    private var beta: URL { directory.appendingPathComponent("beta.txt") }

    func testSingleSourceDirectory() {
        XCTAssertEqual(FinderDimOverlayIdentity.sourceDirectory(for: [alpha, beta])?.standardizedFileURL,
                       directory.standardizedFileURL)
    }

    func testSearchResultsFromMultipleParentsAreRejected() {
        XCTAssertNil(FinderDimOverlayIdentity.sourceDirectory(for: [alpha, URL(fileURLWithPath: "/tmp/elsewhere/beta.txt")]))
    }

    func testEmptyCutSetHasNoSource() {
        XCTAssertNil(FinderDimOverlayIdentity.sourceDirectory(for: []))
    }

    func testExplicitURLWinsOverRecycledCellName() {
        XCTAssertNil(FinderDimOverlayIdentity.match(nodeURL: beta, names: ["alpha.txt"], directory: directory, cutURLs: [alpha]))
    }

    func testExplicitCutURLMatches() {
        XCTAssertEqual(FinderDimOverlayIdentity.match(nodeURL: alpha, names: [], directory: directory, cutURLs: [alpha]), alpha)
    }

    func testNameFallbackRequiresExactFilename() {
        XCTAssertEqual(FinderDimOverlayIdentity.match(nodeURL: nil, names: ["alpha.txt"], directory: directory, cutURLs: [alpha]), alpha)
        XCTAssertNil(FinderDimOverlayIdentity.match(nodeURL: nil, names: ["alpha"], directory: directory, cutURLs: [alpha]))
    }

    func testSameNameInDifferentFolderNeverMatches() {
        XCTAssertNil(FinderDimOverlayIdentity.match(nodeURL: nil, names: ["alpha.txt"], directory: URL(fileURLWithPath: "/tmp/elsewhere"), cutURLs: [alpha]))
    }

    func testAmbiguousNodeNamesAreRejected() {
        XCTAssertNil(FinderDimOverlayIdentity.match(nodeURL: nil, names: ["alpha.txt", "beta.txt"], directory: directory, cutURLs: [alpha, beta]))
    }

    func testRectOutsideViewportIsRejected() {
        XCTAssertNil(FinderDimOverlayGeometry.clip(CGRect(x: 10, y: 10, width: 30, height: 30),
                                                  viewport: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                  window: CGRect(x: 0, y: 0, width: 500, height: 500)))
    }

    func testRectIsClippedToViewport() {
        XCTAssertEqual(FinderDimOverlayGeometry.clip(CGRect(x: 90, y: 120, width: 40, height: 40),
                                                    viewport: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                    window: CGRect(x: 0, y: 0, width: 500, height: 500)),
                       CGRect(x: 100, y: 120, width: 30, height: 40))
    }

    func testZeroSizeRectIsRejected() {
        XCTAssertNil(FinderDimOverlayGeometry.clip(.zero, viewport: CGRect(x: 0, y: 0, width: 200, height: 200),
                                                  window: CGRect(x: 0, y: 0, width: 500, height: 500)))
    }

    func testOverlayBehindFinderIsNotReportedAsDisplayed() {
        XCTAssertFalse(FinderDimOverlayGeometry.isInFront(window: 20, of: 10,
                                                          orderedWindows: [30, 10, 20]))
    }

    func testOverlayAndSourceMustBothBeOnScreen() {
        XCTAssertFalse(FinderDimOverlayGeometry.isInFront(window: 20, of: 10,
                                                          orderedWindows: [30, 10]))
        XCTAssertFalse(FinderDimOverlayGeometry.isInFront(window: 20, of: 10,
                                                          orderedWindows: [20, 30]))
    }

    func testOverlayAboveFinderIsReportedAsDisplayed() {
        XCTAssertTrue(FinderDimOverlayGeometry.isInFront(window: 20, of: 10,
                                                         orderedWindows: [30, 20, 10]))
        XCTAssertFalse(FinderDimOverlayGeometry.isInFront(window: 10, of: 10,
                                                          orderedWindows: [30, 10]))
    }

    func testPathBarConfirmsDirectoryOrSelectedFile() {
        XCTAssertTrue(FinderDimOverlayIdentity.pathBarConfirms([URL(fileURLWithPath: "/"), directory], directory: directory, cutURLs: [alpha]))
        XCTAssertTrue(FinderDimOverlayIdentity.pathBarConfirms([directory, alpha], directory: directory, cutURLs: [alpha]))
    }

    func testAncestorInAnotherFolderPathBarDoesNotConfirmSource() {
        XCTAssertFalse(FinderDimOverlayIdentity.pathBarConfirms([directory, directory.appendingPathComponent("other")], directory: directory, cutURLs: [alpha]))
        XCTAssertFalse(FinderDimOverlayIdentity.pathBarConfirms([directory, beta], directory: directory, cutURLs: [alpha]))
    }

    func testUnrelatedOrMissingBreadcrumbsAreRejected() {
        XCTAssertFalse(FinderDimOverlayIdentity.pathBarConfirms([], directory: directory, cutURLs: [alpha]))
        XCTAssertFalse(FinderDimOverlayIdentity.pathBarConfirms([directory, URL(fileURLWithPath: "/elsewhere")], directory: directory, cutURLs: [alpha]))
    }

    func testListUsesOneVerifiedFileRow() {
        let label = CGRect(x: 130, y: 120, width: 140, height: 18)
        let row = CGRect(x: 100, y: 118, width: 400, height: 22)
        XCTAssertEqual(FinderDimOverlayGeometry.fileRow(label: label, container: row,
            viewport: CGRect(x: 100, y: 100, width: 400, height: 300)), row)
    }

    func testExpandedFolderContainerCannotDimItsDescendants() {
        let label = CGRect(x: 130, y: 120, width: 140, height: 18)
        let subtree = CGRect(x: 100, y: 118, width: 400, height: 220)
        let result = FinderDimOverlayGeometry.fileRow(label: label, container: subtree,
            viewport: CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertLessThan(result.height, 24)
        XCTAssertTrue(result.contains(label))
    }

    func testColumnFallbackIncludesIconButNeverDrawsIntoAdjacentColumn() {
        let label = CGRect(x: 108, y: 120, width: 180, height: 18)
        let column = CGRect(x: 100, y: 100, width: 200, height: 300)
        let result = FinderDimOverlayGeometry.fileRow(label: label, container: nil, viewport: column)
        let clipped = FinderDimOverlayGeometry.clip(result, viewport: column,
            window: CGRect(x: 0, y: 0, width: 700, height: 600))!
        XCTAssertEqual(clipped.minX, column.minX)
        XCTAssertLessThanOrEqual(clipped.maxX, column.maxX)
        XCTAssertTrue(clipped.contains(label))
    }

    func testUnrelatedRowFrameIsNotUsedForFilename() {
        let label = CGRect(x: 130, y: 120, width: 140, height: 18)
        let wrongRow = CGRect(x: 100, y: 180, width: 400, height: 22)
        let result = FinderDimOverlayGeometry.fileRow(label: label, container: wrongRow,
            viewport: CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertFalse(result.intersects(wrongRow))
        XCTAssertTrue(result.contains(label))
    }

    func testSidebarAndPathBarAreNotClassifiedAsFileViews() {
        XCTAssertNil(FinderFileView(identifier: "Sidebar"))
        XCTAssertNil(FinderFileView(identifier: "PathBar"))
        XCTAssertNil(FinderFileView(identifier: "ListViewHeader"))
        XCTAssertEqual(FinderFileView(identifier: "ListView"), .list)
        XCTAssertEqual(FinderFileView(identifier: "ColumnView"), .column)
    }
}
