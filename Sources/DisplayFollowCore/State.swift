import CoreGraphics
import Foundation

/// Displays this tool has turned off or mirrored, by port. Kept on disk so a restarted watcher (or `restore`)
/// can undo it: a display that is off is no longer listed, so its ID can't be looked up again.
public struct RuntimeState: Codable, Equatable {
    public var off: [String: CGDirectDisplayID] = [:]
    public var mirrored: [String: CGDirectDisplayID] = [:]

    public init(off: [String: CGDirectDisplayID] = [:], mirrored: [String: CGDirectDisplayID] = [:]) {
        self.off = off; self.mirrored = mirrored
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        off = try c.decodeIfPresent([String: CGDirectDisplayID].self, forKey: .off) ?? [:]
        mirrored = try c.decodeIfPresent([String: CGDirectDisplayID].self, forKey: .mirrored) ?? [:]
    }

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

    /// Turns back on (or stops mirroring) every display in the state file and clears it. Returns what it found.
    @discardableResult
    public static func restoreAll() -> RuntimeState {
        let state = load()
        for (port, id) in state.off.sorted(by: { $0.key < $1.key }) {
            // A display that can't be turned on (e.g. unplugged) is dropped too: macOS re-enables it on reconnect.
            log(Displays.setEnabled(id, true) ? "restored display \(id) [\(port)]"
                                              : "could not turn on display \(id) [\(port)]; dropping it")
        }
        for (port, id) in state.mirrored.sorted(by: { $0.key < $1.key }) {
            log(Displays.setMirror(id, of: nil) ? "stopped mirroring display \(id) [\(port)]"
                                                : "could not stop mirroring display \(id) [\(port)]; dropping it")
        }
        save(RuntimeState())
        return state
    }
}
