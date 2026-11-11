import CoreGraphics
import Foundation

/// Displays this tool has turned off, by port. Kept on disk so a restarted watcher (or `restore`) can
/// turn them back on: a display that is off is no longer listed, so its ID can't be looked up again.
public struct RuntimeState: Codable, Equatable {
    public var off: [String: CGDirectDisplayID] = [:]

    public init(off: [String: CGDirectDisplayID] = [:]) { self.off = off }
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

    /// Turns every display in the state file back on and clears it. Returns the displays it restored.
    @discardableResult
    public static func restoreAll() -> [String: CGDirectDisplayID] {
        let state = load()
        var failed: [String: CGDirectDisplayID] = [:]
        for (port, id) in state.off.sorted(by: { $0.key < $1.key }) {
            if Displays.setEnabled(id, true) { log("restored display \(id) [\(port)]") } else { failed[port] = id }
        }
        // A display that can't be turned on (e.g. unplugged) is dropped too: macOS re-enables it on reconnect.
        for (port, id) in failed { log("could not turn on display \(id) [\(port)]; dropping it") }
        save(RuntimeState())
        return state.off
    }
}
