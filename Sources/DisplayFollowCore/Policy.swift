import Foundation

/// What the watcher should do after one reading. Pure, so it can be checked offline.
public enum Decision: Equatable {
    case none
    case away(input: Int)   // monitor shows another input: move windows off it
    case back(input: Int)   // monitor shows the Mac again: bring it back
}

public enum Policy {
    /// - Parameters:
    ///   - input: the monitor's current input, or nil if DDC did not answer.
    ///   - macInput: the input the Mac is connected to.
    ///   - isAway: whether the watcher has already turned this monitor off.
    ///   - activeDisplays: number of active displays right now.
    public static func decide(input: Int?, macInput: Int, isAway: Bool, activeDisplays: Int) -> Decision {
        guard let input else { return .none }
        if input != macInput {
            // Never turn off the last active display (e.g. laptop lid closed).
            return !isAway && activeDisplays > 1 ? .away(input: input) : .none
        }
        return isAway ? .back(input: input) : .none
    }
}

extension Policy {
    /// A monitor the watcher turned off is turned back on if DDC has been silent this long:
    /// it may have been powered off, or the Mac can no longer tell what it shows.
    public static func ddcLost(lastReply: Date, now: Date, timeout: TimeInterval) -> Bool {
        timeout > 0 && now.timeIntervalSince(lastReply) > timeout
    }
}

/// Acts on a decision only after it has come out the same for `required` reads in a row,
/// so one bad or transitional DDC reading cannot turn a monitor off.
public struct Confirmer: Equatable {
    var pending: Decision = .none
    var count = 0

    public init() {}

    public mutating func confirm(_ decision: Decision, required: Int) -> Decision {
        guard decision != .none else { self = Confirmer(); return .none }
        if decision == pending { count += 1 } else { pending = decision; count = 1 }
        guard count >= max(required, 1) else { return .none }
        self = Confirmer()
        return decision
    }
}
