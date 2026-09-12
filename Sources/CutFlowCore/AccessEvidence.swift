/// The cached trust flag alone is not proof that an accessibility operation works.
public struct AccessEvidence {
    public enum Probe { case allowed, denied, unavailable }
    public let reportedTrust: Bool
    public let accessibility: Probe
    public let eventTapActive: Bool

    public init(reportedTrust: Bool, accessibility: Probe, eventTapActive: Bool) {
        self.reportedTrust = reportedTrust
        self.accessibility = accessibility
        self.eventTapActive = eventTapActive
    }

    public var hasAccess: Bool {
        if eventTapActive || accessibility == .allowed { return true }
        if accessibility == .denied { return false }
        return reportedTrust
    }
}
