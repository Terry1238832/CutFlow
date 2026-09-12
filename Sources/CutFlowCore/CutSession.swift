import Foundation

/// Only a fresh file clipboard produced after cut can authorize a move.
public struct CutSession {
    public enum State: Equatable {
        case idle
        case awaitingCopy(baseline: Int, owner: String, deadline: TimeInterval)
        case ready(changeCount: Int, owner: String, fileCount: Int)
    }

    public private(set) var state: State = .idle
    public init() {}

    public mutating func begin(changeCount: Int, owner: String, now: TimeInterval) {
        state = .awaitingCopy(baseline: changeCount, owner: owner, deadline: now + 1.5)
    }

    public mutating func observe(changeCount: Int, fileCount: Int, frontmostOwner: String?, now: TimeInterval) {
        switch state {
        case .idle: break
        case let .awaitingCopy(baseline, owner, deadline):
            guard now <= deadline, frontmostOwner == owner else { cancel(); return }
            if changeCount != baseline {
                state = fileCount > 0
                    ? .ready(changeCount: changeCount, owner: owner, fileCount: fileCount)
                    : .idle
            }
        case let .ready(expected, _, _):
            if changeCount != expected { cancel() }
        }
    }

    public func canMove(changeCount: Int, owner: String) -> Bool {
        guard case let .ready(expected, source, _) = state else { return false }
        return expected == changeCount && source == owner
    }

    public mutating func consumeMove(changeCount: Int, owner: String) -> Bool {
        guard canMove(changeCount: changeCount, owner: owner) else { return false }
        cancel()
        return true
    }

    public mutating func cancel() { state = .idle }
}

public enum ShortcutPolicy {
    public static func supports(_ bundleID: String, forkLift: Bool) -> Bool {
        if bundleID == "com.apple.finder" { return true }
        return forkLift && ["com.binarynights.ForkLift", "com.binarynights.ForkLift-3",
                            "com.binarynights.forklift-setapp"].contains(bundleID)
    }

    public static func isTextRole(_ role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
}
