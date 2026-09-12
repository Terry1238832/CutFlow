import XCTest
@testable import CutFlowCore

final class AccessEvidenceTests: XCTestCase {
    func testStaleFalseFlagDoesNotHideSuccessfulAXCall() {
        XCTAssertTrue(AccessEvidence(reportedTrust: false, accessibility: .allowed, eventTapActive: false).hasAccess)
    }
    func testStaleFalseFlagDoesNotHideWorkingEventTap() {
        XCTAssertTrue(AccessEvidence(reportedTrust: false, accessibility: .unavailable, eventTapActive: true).hasAccess)
    }
    func testExplicitDenialOverridesStaleTrueFlag() {
        XCTAssertFalse(AccessEvidence(reportedTrust: true, accessibility: .denied, eventTapActive: false).hasAccess)
    }
    func testNoEvidenceDoesNotGrantAccess() {
        XCTAssertFalse(AccessEvidence(reportedTrust: false, accessibility: .unavailable, eventTapActive: false).hasAccess)
    }
    func testReportedTrustIsFallbackWhenFinderUnavailable() {
        XCTAssertTrue(AccessEvidence(reportedTrust: true, accessibility: .unavailable, eventTapActive: false).hasAccess)
    }
    func testActualEventTapCapabilityIsPreservedWhenAXDenied() {
        XCTAssertTrue(AccessEvidence(reportedTrust: false, accessibility: .denied, eventTapActive: true).hasAccess)
    }
}
