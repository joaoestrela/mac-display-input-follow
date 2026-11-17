// A simulated machine for driving the watcher offline: monitors, their inputs, sleep and failures.
import CoreGraphics
import Foundation

final class FakeSystem: System {
    struct Monitor {
        var identity: MonitorIdentity
        var displayID: CGDirectDisplayID
        var connected = true
        var online = true
        var input: Int? = 17
        var mirroredOnto: CGDirectDisplayID?
    }

    var now = Date(timeIntervalSince1970: 1_000_000)
    var monitors: [String: Monitor] = [:]
    var builtinActive = true
    var graphics: Bool? = true
    var localAwake = true
    var fresh: Bool? = true
    /// The next this many enable (or disable) calls fail.
    var failEnables = 0
    var failDisables = 0
    var actions: [String] = []
    var hooks: [String] = []
    var state = RuntimeState()

    static let msi = MonitorIdentity(name: "MSI", vendor: 1, model: 2, serial: 3)

    init(monitors: [String: Monitor] = ["dispext1": Monitor(identity: msi, displayID: 3)]) {
        self.monitors = monitors
    }

    func externalPorts() -> [PortSnapshot] {
        monitors.filter(\.value.connected).sorted { $0.key < $1.key }
            .map { PortSnapshot(port: $0.key, identity: $0.value.identity, displayID: $0.value.online ? $0.value.displayID : nil) }
    }

    func readInput(port: String) -> Int? { monitors[port].flatMap { $0.connected ? $0.input : nil } }
    func activeDisplayCount() -> Int { (builtinActive ? 1 : 0) + monitors.values.filter { $0.connected && $0.online }.count }
    func anyDisplayAwake() -> Bool { localAwake }
    func freshAnyAwake() -> Bool? { fresh }
    func hasGraphics() -> Bool? { graphics }

    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        actions.append("\(enabled ? "on" : "off") \(id)")
        if enabled, failEnables > 0 { failEnables -= 1; return false }
        if !enabled, failDisables > 0 { failDisables -= 1; return false }
        guard let key = monitors.first(where: { $0.value.displayID == id && $0.value.connected })?.key else { return false }
        monitors[key]?.online = enabled
        return true
    }

    func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?) -> Bool {
        actions.append(target.map { "mirror \(id) onto \($0)" } ?? "unmirror \(id)")
        guard let key = monitors.first(where: { $0.value.displayID == id })?.key else { return false }
        monitors[key]?.mirroredOnto = target
        return true
    }

    func isMirroring(_ id: CGDirectDisplayID) -> Bool { monitors.values.first { $0.displayID == id }?.mirroredOnto != nil }
    func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID? { builtinActive ? 1 : nil }

    func runHook(_ command: String?, event: String, monitor: String, port: String, input: Int) {
        hooks.append(event)
    }

    func loadState() -> RuntimeState { state }
    func saveState(_ state: RuntimeState) { self.state = state }

    var display: Monitor {
        get { monitors["dispext1"]! }
        set { monitors["dispext1"] = newValue }
    }
}

/// A watcher on a fake machine with one monitor whose Mac input is 17.
func simulation(action: AwayAction = .disable, hooks: Bool = false) -> (Watcher, FakeSystem) {
    let fake = FakeSystem()
    var monitor = MonitorConfig(FakeSystem.msi, macInput: 17)
    monitor.action = action
    if hooks { monitor.onAway = "away"; monitor.onBack = "back" }
    var config = Config()
    config.monitors = [monitor]
    return (Watcher(system: fake, config: config), fake)
}

/// Advances the clock a second at a time, ticking the watcher each second.
func run(_ watcher: Watcher, _ fake: FakeSystem, seconds: Int) {
    for _ in 0..<seconds {
        fake.now = fake.now.addingTimeInterval(1)
        watcher.tick()
    }
}

func simulationChecks() {
    do {  // switching away turns the display off; switching back turns it on
        let (w, fake) = simulation(hooks: true)
        run(w, fake, seconds: 3)
        check(fake.actions.isEmpty, "sim: steady on the Mac does nothing")
        fake.display.input = 15
        run(w, fake, seconds: 3)
        check(fake.actions == ["off 3"] && !fake.display.online, "sim: away turns the display off")
        check(fake.state.off == ["dispext1": 3], "sim: away is recorded")
        fake.display.input = 17
        run(w, fake, seconds: 3)
        check(fake.actions == ["off 3", "on 3"] && fake.display.online, "sim: back turns the display on")
        check(fake.hooks == ["away", "back"], "sim: hooks run once each")
        check(fake.state.isEmpty, "sim: back clears the record")
    }
    do {  // a bounce to another input right after turning on is ignored
        let (w, fake) = simulation()
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.display.input = 17
        run(w, fake, seconds: 3)
        fake.display.input = 15
        run(w, fake, seconds: 5)
        check(fake.actions == ["off 3", "on 3"], "sim: bounce while settling is ignored")
        run(w, fake, seconds: 15)
        check(fake.actions == ["off 3", "on 3", "off 3"], "sim: another input after settling turns it off")
    }
    do {  // a dark wake does nothing; a full wake turns displays back on
        let (w, fake) = simulation()
        fake.display.input = 15
        run(w, fake, seconds: 3)
        w.pause("will sleep")
        fake.graphics = false
        run(w, fake, seconds: 120)
        check(fake.actions == ["off 3"], "sim: nothing happens in a dark wake")
        fake.graphics = true
        run(w, fake, seconds: 2)
        check(fake.actions == ["off 3", "on 3"], "sim: full wake turns the display back on")
    }
}
