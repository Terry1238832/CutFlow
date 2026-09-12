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
}
