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
    var local: Displays.State = .awake
    var fresh: Displays.State? = .awake
    /// The next this many enable (or disable) calls fail.
    var failEnables = 0
    var failDisables = 0
    var actions: [String] = []
    var hooks: [String] = []
    var state = RuntimeState()
    /// The state file as it was when a display was last turned off.
    var stateAtLastDisable: RuntimeState?

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
    func displayState() -> Displays.State { local }
    func freshDisplayState() -> Displays.State? { fresh }
    func hasGraphics() -> Bool? { graphics }

    /// Completions of display changes, delivered after the tick that started them (like a child process).
    var pending: [() -> Void] = []

    func flush() {
        let now = pending
        pending = []
        now.forEach { $0() }
    }

    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool, completion: @escaping (Bool) -> Void) {
        actions.append("\(enabled ? "on" : "off") \(id)")
        if !enabled { stateAtLastDisable = state }
        let ok: Bool
        if enabled, failEnables > 0 { failEnables -= 1; ok = false }
        else if !enabled, failDisables > 0 { failDisables -= 1; ok = false }
        else if let key = monitors.first(where: { $0.value.displayID == id })?.key { monitors[key]?.online = enabled; ok = true }
        else { ok = false }
        pending.append { completion(ok) }
    }

    func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?, completion: @escaping (Bool) -> Void) {
        actions.append(target.map { "mirror \(id) onto \($0)" } ?? "unmirror \(id)")
        let key = monitors.first(where: { $0.value.displayID == id })?.key
        if let key { monitors[key]?.mirroredOnto = target }
        pending.append { completion(key != nil) }
    }

    func isMirroring(_ id: CGDirectDisplayID) -> Bool { monitors.values.first { $0.displayID == id }?.mirroredOnto != nil }
    func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID? { builtinActive ? 1 : nil }

    func runHook(_ command: String?, event: String, monitor: String, port: String, input: Int?) {
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
        fake.flush()
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
        run(w, fake, seconds: 3)
        check(fake.actions == ["off 3"], "sim: wake restore waits for wakeGrace")
        run(w, fake, seconds: 4)
        check(fake.actions == ["off 3", "on 3"], "sim: full wake turns the display back on")
        run(w, fake, seconds: 20)
        check(fake.actions == ["off 3", "on 3", "off 3"], "sim: still on the other input after settling: off again")
    }
    do {  // turning on fails for a long time: retries with backoff, never gives up
        let (w, fake) = simulation()
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.failEnables = 1000
        fake.display.input = 17
        run(w, fake, seconds: 3600)
        let tries = fake.actions.filter { $0 == "on 3" }.count
        check(tries > 50 && tries < 80, "sim: failing enable retried about once a minute (\(tries) tries)")
        fake.failEnables = 0
        run(w, fake, seconds: 61)
        check(fake.display.online, "sim: enable that starts working turns the display on")
    }
    do {  // a display left off with no record (state lost) is turned on once the monitor shows the Mac
        let fake = FakeSystem()
        fake.state = RuntimeState(known: ["dispext1": 3])
        fake.display.online = false
        fake.display.input = 15
        var config = Config()
        config.monitors = [MonitorConfig(FakeSystem.msi, macInput: 17)]
        let w = Watcher(system: fake, config: config)
        run(w, fake, seconds: 5)
        check(fake.actions.isEmpty && fake.state.off == ["dispext1": 3], "sim: unrecorded off display is adopted")
        fake.display.input = 17
        run(w, fake, seconds: 2)
        check(fake.actions == ["on 3"] && fake.display.online, "sim: adopted display turned on when back")
    }
    do {  // a disable reported as failed that happened anyway is still followed
        let (w, fake) = simulation()
        fake.display.input = 15
        fake.failDisables = 1
        run(w, fake, seconds: 3)
        fake.display.online = false  // it went off after all
        run(w, fake, seconds: 2)
        fake.display.input = 17
        run(w, fake, seconds: 2)
        check(fake.display.online, "sim: display that went off despite an error is turned back on")
    }
    do {  // the record is written before disabling
        let (w, fake) = simulation()
        fake.display.input = 15
        run(w, fake, seconds: 3)
        check(fake.stateAtLastDisable?.off == ["dispext1": 3], "sim: away recorded before the disable")
    }
    do {  // monitor gone while off: retried until on; an ID now on another port is dropped
        let (w, fake) = simulation()
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.display.connected = false
        fake.failEnables = 3
        run(w, fake, seconds: 30)
        check(fake.state.off.isEmpty && fake.actions.filter { $0 == "on 3" }.count == 4,
              "sim: gone while off is retried until it works")
        let (w2, fake2) = simulation()
        fake2.monitors["dispext2"] = FakeSystem.Monitor(identity: MonitorIdentity(name: "Other", vendor: 9, model: 9, serial: 9), displayID: 4)
        fake2.display.input = 15
        run(w2, fake2, seconds: 3)
        fake2.display.connected = false
        fake2.monitors["dispext2"]?.displayID = 3  // ID reused by another monitor
        fake2.failEnables = 1000
        run(w2, fake2, seconds: 5)
        check(fake2.state.off.isEmpty, "sim: record whose ID is on another port is dropped")
    }
    do {  // hooks stay balanced when the monitor is unplugged while away
        let (w, fake) = simulation(action: .none, hooks: true)
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.display.connected = false
        run(w, fake, seconds: 2)
        check(fake.hooks == ["away", "back"], "sim: unplugged while away still runs onBack")
    }
    do {  // onBack waits until the display is actually on
        let (w, fake) = simulation(hooks: true)
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.failEnables = 1
        fake.display.input = 17
        run(w, fake, seconds: 2)
        check(fake.hooks == ["away"], "sim: onBack not run while the enable failed")
        run(w, fake, seconds: 3)
        check(fake.hooks == ["away", "back"] && fake.display.online, "sim: onBack once the display is on")
    }
    do {  // lid closed with the external display off: nothing on screen, so turn it on
        let (w, fake) = simulation()
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.builtinActive = false
        fake.local = .none
        fake.fresh = Displays.State.none
        run(w, fake, seconds: 4)
        check(fake.display.online, "sim: nothing on screen turns the display back on")
    }
    do {  // a stale local view of the displays does not pause the watcher
        let (w, fake) = simulation()
        fake.local = .asleep
        fake.fresh = .awake
        run(w, fake, seconds: 10)
        check(!w.sleeping, "sim: stale local view does not pause")
        fake.fresh = .asleep
        run(w, fake, seconds: 4)
        check(w.sleeping, "sim: displays asleep pauses")
        fake.local = .awake
        fake.fresh = .awake
        run(w, fake, seconds: 4)
        check(!w.sleeping, "sim: displays awake resumes")
    }
    do {  // a turn-off that keeps failing backs off instead of retrying every other second
        let (w, fake) = simulation()
        fake.failDisables = 1000
        fake.display.input = 15
        run(w, fake, seconds: 120)
        let tries = fake.actions.filter { $0 == "off 3" }.count
        check(tries >= 4 && tries <= 8, "sim: failing disable backs off (\(tries) tries in 2 minutes)")
    }
    do {  // mirroring away and back, with hooks
        let (w, fake) = simulation(action: .mirror, hooks: true)
        fake.display.input = 15
        run(w, fake, seconds: 3)
        fake.display.input = 17
        run(w, fake, seconds: 4)
        check(fake.actions == ["mirror 3 onto 1", "unmirror 3"] && fake.hooks == ["away", "back"], "sim: mirror away and back")
    }
    do {  // stop: entries that could not be restored stay in the state file
        let state = RuntimeState(off: ["dispext1": 3, "dispext2": 4])
        let left = StateStore.restore(state, enable: { $0 == 4 }, unmirror: { _ in true })
        check(left.off == ["dispext1": 3], "restore keeps what could not be turned on")
    }
}
