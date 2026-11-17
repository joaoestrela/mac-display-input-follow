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
    /// This process's view of whether anything is on screen. Can go stale; see `freshDisplayState`.
    func displayState() -> Displays.State
    /// The same question asked of a fresh process. nil if that could not be run.
    func freshDisplayState() -> Displays.State?
    /// The kernel's graphics capability: false while asleep or in a dark wake, nil if unreadable.
    func hasGraphics() -> Bool?
    /// Display changes complete later, on the main queue, with whether they reported success.
    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool, completion: @escaping (Bool) -> Void)
    func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?, completion: @escaping (Bool) -> Void)
    func isMirroring(_ id: CGDirectDisplayID) -> Bool
    func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID?
    func runHook(_ command: String?, event: String, monitor: String, port: String, input: Int?)
    func loadState() -> RuntimeState
    func saveState(_ state: RuntimeState)
}

public final class RealSystem: System {
    /// The last discovered ports, kept so DDC reads reuse their AV services.
    var discovered: [String: ExternalPort] = [:]
    var snapshots: [PortSnapshot] = []
    var discoveredAt = Date.distantPast
    var discoveredOnline: [CGDirectDisplayID] = []
    /// Port discovery walks the IORegistry and CoreDisplay; it is redone at most this often, or sooner when
    /// the set of online displays changes or a display change completes.
    static let discoveryInterval: TimeInterval = 5

    public init() {}

    public var now: Date { Date() }

    public func externalPorts() -> [PortSnapshot] {
        let online = Displays.online().map(\.id).sorted()
        if now.timeIntervalSince(discoveredAt) < Self.discoveryInterval, online == discoveredOnline { return snapshots }
        let ports = Ports.external()
        discovered = Dictionary(ports.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
        snapshots = ports.map { PortSnapshot(port: $0.port, identity: $0.identity, displayID: $0.displayID) }
        discoveredAt = now
        discoveredOnline = online
        return snapshots
    }

    /// Forces the next `externalPorts` to rediscover.
    func invalidatePorts() { discoveredAt = .distantPast }

    public func readInput(port: String) -> Int? { discovered[port]?.readInput(attempts: 2) }
    public func activeDisplayCount() -> Int { Displays.activeCount() }
    public func displayState() -> Displays.State { Displays.state() }

    public func freshDisplayState() -> Displays.State? {
        Child.run(["display-state"], timeout: 5).flatMap(Displays.State.init(rawValue:))
    }

    public func hasGraphics() -> Bool? { Power.hasGraphics() }
    /// How long a display change may take before its child process is killed and it counts as failed.
    static let changeTimeout: TimeInterval = 15

    public func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool, completion: @escaping (Bool) -> Void) {
        change([enabled ? "on" : "off", String(id)], completion: completion) { Displays.setEnabled(id, enabled) }
    }

    public func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?, completion: @escaping (Bool) -> Void) {
        let args = target.map { ["mirror", String(id), String($0)] } ?? ["unmirror", String(id)]
        change(args, completion: completion) { Displays.setMirror(id, of: target) }
    }

    /// Runs a display change in a child process; in this process only if the binary can't be run.
    func change(_ args: [String], completion: @escaping (Bool) -> Void, inProcess: @escaping () -> Bool) {
        let done: (Bool) -> Void = { [weak self] ok in
            self?.invalidatePorts()
            completion(ok)
        }
        guard Child.executable != nil else { done(inProcess()); return }
        Child.start(args, timeout: Self.changeTimeout) { done($0 == 0) }
    }

    public func isMirroring(_ id: CGDirectDisplayID) -> Bool { Displays.isMirroring(id) }
    public func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID? { Displays.mirrorTarget(for: id) }

    public func runHook(_ command: String?, event: String, monitor: String, port: String, input: Int?) {
        Hooks.run(command, event: event, monitor: monitor, port: port, input: input)
    }

    public func loadState() -> RuntimeState { StateStore.load() }
    public func saveState(_ state: RuntimeState) { StateStore.save(state) }
}
