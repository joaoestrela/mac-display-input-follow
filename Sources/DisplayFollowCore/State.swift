import CoreGraphics
import Foundation

/// What this tool has done to displays, by port. Kept on disk so a restarted watcher (or `restore`) can undo
/// it: a display that is off is no longer listed, so its ID can't be looked up again.
public struct RuntimeState: Codable, Equatable {
    /// Displays turned off.
    public var off: [String: CGDirectDisplayID] = [:]
    /// Displays mirrored onto another one.
    public var mirrored: [String: CGDirectDisplayID] = [:]
    /// The last display ID seen on each port, so a display found off (for whatever reason) can be turned on.
    public var known: [String: CGDirectDisplayID] = [:]
    /// Ports whose `onAway` hook ran and whose `onBack` hook has not run yet.
    public var hooksAway: [String] = []

    public init(off: [String: CGDirectDisplayID] = [:], mirrored: [String: CGDirectDisplayID] = [:],
                known: [String: CGDirectDisplayID] = [:], hooksAway: [String] = []) {
        self.off = off; self.mirrored = mirrored; self.known = known; self.hooksAway = hooksAway
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        off = try c.decodeIfPresent([String: CGDirectDisplayID].self, forKey: .off) ?? [:]
        mirrored = try c.decodeIfPresent([String: CGDirectDisplayID].self, forKey: .mirrored) ?? [:]
        known = try c.decodeIfPresent([String: CGDirectDisplayID].self, forKey: .known) ?? [:]
        hooksAway = try c.decodeIfPresent([String].self, forKey: .hooksAway) ?? []
    }

    /// Nothing turned off or mirrored.
    public var isEmpty: Bool { off.isEmpty && mirrored.isEmpty }
}

public enum StateStore {
    /// `$XDG_STATE_HOME/display-follow/state.json`, defaulting to `~/.local/state`.
    public static var url: URL {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Paths.home.appendingPathComponent(".local/state")
        return base.appendingPathComponent("display-follow/state.json")
    }

    public static func load() -> RuntimeState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(RuntimeState.self, from: data)
        else { return RuntimeState() }
        return state
    }

    public static func save(_ state: RuntimeState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            log("could not write \(url.path): \(error)")
        }
    }

    /// Turns back on (or stops mirroring) every display in the state file. Entries that fail stay in the
    /// file, so the next watcher (or `restore`) still knows to turn them on. Returns what it found.
    @discardableResult
    public static func restoreAll(enable: (CGDirectDisplayID) -> Bool = { Displays.setEnabled($0, true) },
                                  unmirror: (CGDirectDisplayID) -> Bool = { Displays.setMirror($0, of: nil) }) -> RuntimeState {
        let state = load()
        save(restore(state, enable: enable, unmirror: unmirror))
        return state
    }

    /// The state left after trying to undo everything in `state`: only what could not be undone.
    public static func restore(_ state: RuntimeState, enable: (CGDirectDisplayID) -> Bool,
                               unmirror: (CGDirectDisplayID) -> Bool) -> RuntimeState {
        var left = state
        for (port, id) in state.off.sorted(by: { $0.key < $1.key }) {
            if enable(id) {
                log("restored display \(id) [\(port)]")
                left.off[port] = nil
            } else {
                log("could not turn on display \(id) [\(port)]; keeping it in \(url.path)")
            }
        }
        for (port, id) in state.mirrored.sorted(by: { $0.key < $1.key }) {
            if unmirror(id) {
                log("stopped mirroring display \(id) [\(port)]")
                left.mirrored[port] = nil
            } else {
                log("could not stop mirroring display \(id) [\(port)]; keeping it in \(url.path)")
            }
        }
        return left
    }
}
