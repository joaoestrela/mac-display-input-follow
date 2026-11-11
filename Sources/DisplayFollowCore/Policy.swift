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
