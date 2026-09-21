import XCTest
@testable import CutFlow

final class FinderPasteDestinationTests: XCTestCase {
    private let parent = URL(fileURLWithPath: "/tmp/cutflow-parent", isDirectory: true)
    private var folder: URL { parent.appendingPathComponent("目标文件夹", isDirectory: true) }
    private var file: URL { parent.appendingPathComponent("文件.txt") }

    func testOneSelectedFolderBecomesDestination() {
        XCTAssertEqual(FinderPasteDestination.decide(selected: [folder], cutFiles: [file], isFolder: { _ in true }), .folder(folder))
    }
    func testSelectedFileAndEmptyOrMultipleSelectionKeepCurrentDirectory() {
        XCTAssertEqual(FinderPasteDestination.decide(selected: [file], cutFiles: [], isFolder: { _ in false }), .currentDirectory)
        XCTAssertEqual(FinderPasteDestination.decide(selected: [], cutFiles: [], isFolder: { _ in true }), .currentDirectory)
        XCTAssertEqual(FinderPasteDestination.decide(selected: [folder, parent], cutFiles: [], isFolder: { _ in true }), .currentDirectory)
    }
    func testDuplicateAXRepresentationsStillDescribeOneFolder() {
        XCTAssertEqual(FinderPasteDestination.decide(selected: [folder, folder], cutFiles: [file], isFolder: { _ in true }), .folder(folder))
    }
    func testCannotMoveFolderIntoItselfOrItsDescendant() {
        for destination in [folder, folder.appendingPathComponent("child")] {
            guard case .unavailable = FinderPasteDestination.decide(selected: [destination], cutFiles: [folder], isFolder: { _ in true }) else {
                return XCTFail("Self/descendant destination must be rejected")
            }
        }
    }
    func testSimilarPrefixSiblingIsAllowed() {
        let sibling = parent.appendingPathComponent("目标文件夹2")
        XCTAssertEqual(FinderPasteDestination.decide(selected: [sibling], cutFiles: [folder], isFolder: { _ in true }), .folder(sibling))
    }
    func testMerelySelectedFolderIsNotMistakenForOpenedDirectory() {
        for view: FinderFileView in [.icon, .list, .gallery] {
            XCTAssertEqual(FinderPasteDestination.currentDirectory(document: nil, breadcrumbs: [parent, folder],
                selected: [folder], view: view, isFolder: { _ in true })?.path, parent.path)
        }
    }
    func testOpenedFolderWithNoSelectionIsConfirmed() {
        XCTAssertEqual(FinderPasteDestination.currentDirectory(document: nil, breadcrumbs: [parent, folder],
            selected: [], view: .list)?.path, folder.path)
    }
    func testRememberedSelectionInsideTargetStillConfirmsTargetDirectory() {
        let child = folder.appendingPathComponent("remembered.txt")
        XCTAssertEqual(FinderPasteDestination.currentDirectory(document: nil, breadcrumbs: [parent, folder, child],
            selected: [child], view: .list)?.path, folder.path)
    }
    func testColumnFolderSelectionAlreadyDisplaysThatDirectory() {
        XCTAssertEqual(FinderPasteDestination.currentDirectory(document: nil, breadcrumbs: [parent, folder],
            selected: [folder], view: .column, isFolder: { _ in true })?.path, folder.path)
    }
    func testUnrelatedBreadcrumbsCannotConfirmDestination() {
        XCTAssertNil(FinderPasteDestination.currentDirectory(document: nil,
            breadcrumbs: [folder, URL(fileURLWithPath: "/elsewhere")], selected: [], view: .list))
    }
    func testWindowDocumentTakesPriorityOverSelectedBreadcrumb() {
        XCTAssertEqual(FinderPasteDestination.currentDirectory(document: parent, breadcrumbs: [parent, folder],
            selected: [folder], view: .list)?.path, parent.path)
    }

    func testMultipleSelectedIconsWithoutURLsKeepCurrentDirectory() {
        XCTAssertEqual(FinderPasteDestination.decide(selection: .init(urls: [], directory: parent, count: 2),
                                                     cutFiles: [file]), .currentDirectory)
    }

    func testOneUnresolvedSelectedItemCannotBecomeGuessedDestination() {
        guard case .unavailable = FinderPasteDestination.decide(selection: .init(urls: [], directory: parent, count: 1),
                                                                cutFiles: [file]) else {
            return XCTFail("Unknown single selection must not be treated as an empty selection")
        }
    }
}
