import CoreGraphics
import Foundation

/// An external connection as the watcher sees it: port name, monitor identity and (if on) display ID.
public struct PortSnapshot: Equatable {
    public let port: String
    public let identity: MonitorIdentity?
    public let displayID: CGDirectDisplayID?

    public init(port: String, identity: MonitorIdentity?, displayID: CGDirectDisplayID?) {
        self.port = port; self.identity = identity; self.displayID = displayID
    }
}

/// Everything the watcher reads from or does to the machine. `RealSystem` talks to macOS; the offline
/// checks drive the watcher through a simulated one.
public protocol System: AnyObject {
    var now: Date { get }
    func externalPorts() -> [PortSnapshot]
    /// The monitor's input over DDC, or nil if it did not answer.
    func readInput(port: String) -> Int?
    func activeDisplayCount() -> Int
    /// This process's view: is any active display awake? Can go stale; see `freshAnyAwake`.
    func anyDisplayAwake() -> Bool
    /// The same question asked of a fresh process. nil if that could not be run.
    func freshAnyAwake() -> Bool?
    /// The kernel's graphics capability: false while asleep or in a dark wake, nil if unreadable.
    func hasGraphics() -> Bool?
    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool
    func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?) -> Bool
    func isMirroring(_ id: CGDirectDisplayID) -> Bool
    func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID?
    func runHook(_ command: String?, event: String, monitor: String, port: String, input: Int)
    func loadState() -> RuntimeState
    func saveState(_ state: RuntimeState)
}

public final class RealSystem: System {
    /// The last discovered ports, kept so DDC reads reuse their AV services.
    var discovered: [String: ExternalPort] = [:]

    public init() {}

    public var now: Date { Date() }

    public func externalPorts() -> [PortSnapshot] {
        let ports = Ports.external()
        discovered = Dictionary(ports.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
        return ports.map { PortSnapshot(port: $0.port, identity: $0.identity, displayID: $0.displayID) }
    }

    public func readInput(port: String) -> Int? { discovered[port]?.readInput() }
    public func activeDisplayCount() -> Int { Displays.activeCount() }
    public func anyDisplayAwake() -> Bool { Displays.anyAwake() }

    public func freshAnyAwake() -> Bool? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = exe
        process.arguments = ["displays-awake"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    public func hasGraphics() -> Bool? { Power.hasGraphics() }
    public func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool { Displays.setEnabled(id, enabled) }
    public func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?) -> Bool { Displays.setMirror(id, of: target) }
    public func isMirroring(_ id: CGDirectDisplayID) -> Bool { Displays.isMirroring(id) }
    public func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID? { Displays.mirrorTarget(for: id) }

    public func runHook(_ command: String?, event: String, monitor: String, port: String, input: Int) {
        Hooks.run(command, event: event, monitor: monitor, port: port, input: input)
    }

    public func loadState() -> RuntimeState { StateStore.load() }
    public func saveState(_ state: RuntimeState) { StateStore.save(state) }
}
