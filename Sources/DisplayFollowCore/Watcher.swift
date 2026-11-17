import AppKit
import CoreGraphics
import Foundation

/// Follows each external monitor's input and turns its display off, mirrors it or runs hooks.
///
/// Each tick reconciles every port from what is observed rather than from what was attempted: a display
/// that is off while its monitor shows the Mac (or after a wake, or with nothing else on screen) is turned
/// back on, retrying with backoff until it is, whatever got it there. The last display ID seen on each port
/// is kept on disk so this works after a restart too.
public final class Watcher {
    let system: System
    let configURL: URL
    /// Set when the config is given up front (offline checks): it is then never reloaded from disk.
    let fixedConfig: Bool
    let dryRun: Bool
    var config = Config()
    var configDate: Date?
    var timer: Timer?

    /// How a monitor was handled when it switched away.
    enum AwayMode { case off, mirrored, hooksOnly }

    /// A display being turned back on: why, and when to try next.
    struct Restore {
        var reason: String
        var attempts = 0
        var next: Date
    }

    struct PortState {
        var identity: MonitorIdentity?
        /// The last display ID seen on this port. A display that is off is not listed, so it is remembered.
        var displayID: CGDirectDisplayID?
        var away: AwayMode?
        var confirmer = Confirmer()
        var lastReply: Date
        /// `onAway` ran and `onBack` has not yet.
        var hooksAway = false
        /// When this tool last turned the display back on; see `Policy.settling`.
        var turnedOnAt: Date?
        var settleLogged = false
        var restore: Restore?
        /// Turn the display back on regardless of input: set at wake (see `resume`).
        var restoreAfterWake = false
        /// After a turn-off or mirror reported as failed: don't try again before this.
        var nextChange: Date?
        var changeFailures = 0
        var isAway: Bool { away != nil }
    }
    var ports: [String: PortState] = [:]
    /// Ports with a display change running (in a child process); they are left alone until it finishes.
    var inFlight: Set<String> = []

    /// Whether the watcher is following the monitors or paused because the Mac or its displays sleep
    /// (DDC polling then could keep a monitor awake).
    enum Activity: Equatable {
        case running
        /// System sleep or a dark wake; `sawNoGraphics` once the graphics capability was seen off.
        case pausedForSystem(since: Date, sawNoGraphics: Bool)
        case pausedForDisplays(since: Date)
    }
    var activity = Activity.running
    var sleeping: Bool { activity != .running }
    /// Consecutive ticks that found every display asleep.
    var asleepReads = 0
    var resumeAt = Date.distantPast
    var signalSources: [DispatchSourceSignal] = []

    public init(system: System = RealSystem(), configURL: URL = Paths.config, config: Config? = nil, dryRun: Bool = false) {
        self.system = system
        self.configURL = configURL
        self.fixedConfig = config != nil
        self.config = config ?? Config()
        self.dryRun = dryRun
        if !dryRun { adoptState() }
    }

    public func run() -> Never {
        log("started (config \(configURL.path)\(dryRun ? ", dry run" : ""))")
        handleSignals()
        reloadConfigIfChanged()
        observeSleep()
        RunLoop.main.run()
        exit(0)
    }

    /// Picks up edits to the config file (including `display-follow setup`) without a restart.
    func reloadConfigIfChanged() {
        guard !fixedConfig else { return }
        let date = ConfigStore.modificationDate(configURL)
        guard timer == nil || date != configDate else { return }
        configDate = date
        do {
            if let loaded = try ConfigStore.load(configURL) {
                config = loaded
                log("loaded config: \(config.monitors.map { "\($0.name) (mac input \($0.macInput))" }.joined(separator: ", "))")
            } else {
                config = Config()
                log("no config at \(configURL.path); run `display-follow setup` while the Mac's input is showing")
            }
        } catch {
            log("ignoring invalid config: \(error)")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(config.interval, 0.2), repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Picks up what a previous run did, so those displays are still followed (and turned back on).
    func adoptState() {
        let state = system.loadState()
        let now = system.now
        for (port, id) in state.known { ports[port] = PortState(displayID: id, lastReply: now) }
        for (port, id) in state.off {
            ports[port, default: PortState(lastReply: now)].displayID = id
            ports[port]?.away = .off
            log("display \(id) [\(port)] was turned off by a previous run")
        }
        for (port, id) in state.mirrored {
            ports[port, default: PortState(lastReply: now)].displayID = id
            ports[port]?.away = .mirrored
            log("display \(id) [\(port)] was mirrored by a previous run")
        }
        for port in state.hooksAway { ports[port, default: PortState(lastReply: now)].hooksAway = true }
    }

    func saveState() {
        guard !dryRun else { return }
        system.saveState(RuntimeState(off: ports.compactMapValues { $0.away == .off ? $0.displayID : nil },
                                      mirrored: ports.compactMapValues { $0.away == .mirrored ? $0.displayID : nil },
                                      known: ports.compactMapValues(\.displayID),
                                      hooksAway: ports.filter(\.value.hooksAway).map(\.key).sorted()))
    }

    /// On stop (launchctl bootout, Ctrl-C, logout) turn back on every display this tool turned off.
    func handleSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                log("stopping (signal \(sig))")
                if self?.dryRun == false { StateStore.restoreAll() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        // Only system sleep and wake. The "screens did sleep/wake" notifications are unreliable for an
        // agent without an NSApplication: missed on real display sleep, and posted on their own while a
        // display is turned off (a sleep with no wake left the watcher paused). Display sleep is polled.
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] note in
            self?.pause(note.name.rawValue)
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] note in
            // A wake without graphics is a dark wake; the tick resumes once the screens are on.
            guard self?.system.hasGraphics() != false else { return }
            self?.resume(note.name.rawValue)
        }
    }

    enum PauseReason { case system, displays }

    func pause(_ reason: String, for kind: PauseReason = .system) {
        let now = system.now
        switch (activity, kind) {
        case (.running, .system), (.pausedForDisplays, .system):
            // A display-sleep pause becomes a system one when the Mac goes to sleep.
            activity = .pausedForSystem(since: now, sawNoGraphics: false)
        case (.running, .displays):
            activity = .pausedForDisplays(since: now)
        default:
            return
        }
        log("paused (\(reason))")
    }

    /// While asleep the other source may have gone away (or the monitor been powered off and on). A monitor
    /// left on an input with no signal never comes back to the Mac by itself, because a display turned off
    /// sends no signal for its auto input-select to find. So every display turned off is turned back on once
    /// `wakeGrace` is over; the watcher turns it off again if the other input is still in use. Mirrored
    /// displays still send a signal and are left alone.
    func resume(_ reason: String) {
        resumeAt = system.now.addingTimeInterval(config.wakeGrace)
        for key in ports.keys {
            ports[key]?.confirmer = Confirmer()
            // Time asleep is not DDC silence.
            ports[key]?.lastReply = resumeAt
            if ports[key]?.away == .off { ports[key]?.restoreAfterWake = true }
        }
        if sleeping { log("resuming in \(Int(config.wakeGrace))s (\(reason))") }
        activity = .running
        asleepReads = 0
    }

    /// Pauses while every display is asleep (two reads in a row, so a display change can't trip it)
    /// and resumes when one wakes. Returns false while paused.
    ///
    /// This process's own view of the displays can go stale (seen after a system sleep: every display
    /// still read asleep an hour after they woke, so the watcher never resumed). It is only a cheap first
    /// check; pausing and resuming go by a fresh process (`display-follow displays-awake`), asked at
    /// most every `freshCheckInterval`.
    ///
    /// System sleep goes by the kernel's graphics capability: off while asleep and in a dark wake
    /// (maintenance wakes with the screens off, during which timers do fire), on after a full wake.
    /// A system-sleep pause ends only when it is back, so a dark wake never resumes the watcher or
    /// tries to turn displays on, and a full wake resumes it even without the wake notification.
    func followDisplaySleep() -> Bool {
        let now = system.now
        let graphics = system.hasGraphics()
        if graphics == false {
            pause("no graphics: asleep or dark wake")
            if case .pausedForSystem(let since, _) = activity { activity = .pausedForSystem(since: since, sawNoGraphics: true) }
            return false
        }
        switch activity {
        case .pausedForSystem(let since, let sawNoGraphics):
            // Right after the will-sleep notification graphics still reads on: don't resume on that.
            guard sawNoGraphics || now.timeIntervalSince(since) > systemPauseMinimum else { return false }
            if graphics == true {
                resume("full wake")
                return true
            }
            // Graphics can't be read: go by the displays instead.
            guard let fresh = freshState(pausedSince: since), fresh != .asleep else { return false }
            resume("displays awake")
            return true
        case .pausedForDisplays(let since):
            guard let fresh = freshState(pausedSince: since), fresh != .asleep else { return false }
            resume("displays awake")
            return true
        case .running:
            asleepReads = system.displayState() == .awake ? 0 : asleepReads + 1
            guard asleepReads >= 2, let fresh = freshState() else { return true }
            switch fresh {
            case .awake:
                if !loggedStaleView { log("displays read asleep here but awake in a fresh process; not pausing"); loggedStaleView = true }
            case .asleep:
                pause("displays asleep", for: .displays)
            case .none:
                break  // nothing on screen: not asleep, and `reconcile` turns a display back on
            }
            return !sleeping
        }
    }

    /// A system-sleep pause is ended by graphics being on only after graphics was seen off, or after this
    /// long (longer than powerd's will-sleep window, so a slow sleep can't end it).
    let systemPauseMinimum: TimeInterval = 60
    let freshCheckInterval: TimeInterval = 3
    /// After a minute of pause, fresh checks slow down to this.
    let slowFreshCheckInterval: TimeInterval = 10
    var nextFreshCheck = Date.distantPast
    var loggedStaleView = false
    var lastFresh: Displays.State?

    /// A fresh process's view of the displays, asked at most every `freshCheckInterval` (nil in between),
    /// less often once a pause is over a minute old. If the fresh process can't be run, the displays count
    /// as awake: this process's own view is the one known to go stale.
    func freshState(pausedSince: Date? = nil) -> Displays.State? {
        let now = system.now
        guard now >= nextFreshCheck else { return nil }
        let slow = pausedSince.map { now.timeIntervalSince($0) > 60 } ?? false
        nextFreshCheck = now.addingTimeInterval(slow ? slowFreshCheckInterval : freshCheckInterval)
        lastFresh = system.freshDisplayState() ?? .awake
        return lastFresh
    }

    /// Nothing on screen (lid closed, the external display off): then the display this tool turned off has to
    /// come back, whatever the monitor shows. Checked locally first, then confirmed by a fresh process.
    func nothingOnScreen() -> Bool {
        guard system.activeDisplayCount() == 0 else { return false }
        if let fresh = freshState() { return fresh == .none }
        return lastFresh == Displays.State.none
    }

    func tick() {
        reloadConfigIfChanged()
        guard followDisplaySleep() else { return }
        guard system.now >= resumeAt else { return }
        defer { saveState() }
        let connected = system.externalPorts()
        var active = system.activeDisplayCount()
        var seen: [String: PortState] = [:]
        let onlineIDs = Set(connected.compactMap(\.displayID))

        // Ports that are gone (unplugged, or the link dropped out in standby).
        for (port, var state) in ports where !connected.contains(where: { $0.port == port }) {
            let name = "\(state.identity?.name ?? "display") [\(port)]"
            guard state.away == .off, let id = state.displayID else {
                if state.hooksAway { forgetHooks(&state, port: port) }
                continue
            }
            if onlineIDs.contains(id) {
                // The ID now belongs to a display on another port: it was reused after a reconnect.
                log("\(name) is gone and display \(id) is now on another port; forgetting it")
                if state.hooksAway { forgetHooks(&state, port: port) }
                continue
            }
            // Turn it on and forget it only once that works: a display left off and forgotten stays off.
            // (Once on, `away` is cleared and the next tick forgets it above.)
            restoreDisplay(&state, port: port, reason: "disconnected while off")
            seen[port] = state
        }

        for snap in connected {
            var state = ports[snap.port] ?? PortState(lastReply: system.now)
            if let identity = snap.identity { state.identity = identity }
            if let id = snap.displayID { state.displayID = id }
            if !inFlight.contains(snap.port) { reconcile(&state, snap: snap, active: &active) }
            seen[snap.port] = state
        }
        ports = seen
    }

    /// One port, one tick.
    func reconcile(_ state: inout PortState, snap: PortSnapshot, active: inout Int) {
        let now = system.now
        let port = snap.port
        let online = snap.displayID != nil
        let name = "\(state.identity?.name ?? "display") [\(port)]"

        // Observed on: whatever we thought, it is on now (our restore worked, or it was turned on elsewhere).
        if online, state.away == .off {
            state.away = nil
            state.restore = nil
        }
        if online { state.restoreAfterWake = false }
        if let id = snap.displayID, state.away == .mirrored, !system.isMirroring(id) { state.away = nil }

        guard let identity = state.identity, let monitor = config.monitor(identity) else {
            // Not (or no longer) in the config: put back whatever was done to it.
            if !online, state.away == .off { restoreDisplay(&state, port: port, reason: "not in the config") }
            if state.away == .mirrored, let id = state.displayID { unmirror(&state, port: port, id: id) }
            if state.away == .hooksOnly { state.away = nil }
            return
        }

        // Hooks-only monitors and monitors that are on need no display ID; the rest can't be acted on without one.
        let input = system.readInput(port: port)
        if input != nil { state.lastReply = now }

        // Off: decide whether it has to come back on. A display found off that this run did not turn off
        // (state lost, a restart in the middle of a change, a change reported as failed that happened anyway)
        // is followed like one it did.
        if !online, monitor.action == .disable, state.displayID != nil {
            if state.away == nil {
                log("\(name): display \(state.displayID!) is off; following it")
                state.away = .off
            }
            let reason: String?
            if let input, input == monitor.macInput { reason = "back on input \(input)" }
            else if state.restoreAfterWake { reason = "turning back on after wake" }
            else if Policy.ddcLost(lastReply: state.lastReply, now: now, timeout: config.ddcLossTimeout) {
                reason = "silent over DDC for \(Int(config.ddcLossTimeout))s"
            } else if nothingOnScreen() { reason = "no other display is on" }
            else { reason = nil }
            if let reason {
                restoreDisplay(&state, port: port, reason: reason)
            } else {
                state.restore = nil
            }
            if !state.isAway, let input { runBackHookIfDue(&state, monitor: monitor, port: port, input: input) }
            return
        }

        if state.away == .mirrored || state.away == .hooksOnly,
           Policy.ddcLost(lastReply: state.lastReply, now: now, timeout: config.ddcLossTimeout) {
            log("\(name) silent over DDC for \(Int(config.ddcLossTimeout))s -> restoring it")
            if state.away == .mirrored, let id = state.displayID { unmirror(&state, port: port, id: id) } else { state.away = nil }
            return
        }

        if let next = state.nextChange, now < next { return }
        var decision = Policy.decide(input: input, macInput: monitor.macInput, isAway: state.isAway,
                                     activeDisplays: active, needsOtherDisplay: monitor.action != .none)
        if case .away(let other) = decision, Policy.settling(turnedOnAt: state.turnedOnAt, now: now) {
            if !state.settleLogged {
                state.settleLogged = true
                log("\(name) reports input \(other) while settling after being turned on; ignoring")
            }
            decision = .none
        }
        switch state.confirmer.confirm(decision, required: config.confirmReads) {
        case .none:
            break
        case .away(let input):
            let label = "\(name) on input \(input)"
            switch monitor.action {
            case .disable:
                guard let id = snap.displayID else { return }
                log("\(label) -> disabling display \(id)")
                // Recorded first, so a crash or a change reported as failed can't leave it off unrecorded.
                state.away = .off
                ports[port] = state
                saveState()
                active -= 1
                change(port: port, what: "disable display \(id)", { self.system.setEnabled(id, false, completion: $0) }) { state, ok in
                    // If it went off anyway, the next tick sees it off and follows it.
                    if !ok { state.away = nil }
                }
            case .mirror:
                guard let id = snap.displayID, let target = system.mirrorTarget(for: id) else { return }
                log("\(label) -> mirroring display \(id) onto \(target)")
                state.away = .mirrored
                change(port: port, what: "mirror display \(id)", { self.system.setMirror(id, of: target, completion: $0) }) { state, ok in
                    if !ok { state.away = nil }
                }
            case .none:
                log(label)
                state.away = .hooksOnly
            }
            if !state.hooksAway {
                hook(monitor.onAway, event: "away", monitor: monitor.name, port: port, input: input)
                state.hooksAway = true
            }
        case .back(let input):
            log("\(name) back on input \(input)")
            if state.away == .mirrored, let id = state.displayID { unmirror(&state, port: port, id: id) } else { state.away = nil }
        }
        if !state.isAway, let input { runBackHookIfDue(&state, monitor: monitor, port: port, input: input) }
    }

    /// Turns the port's display back on, at most as often as the backoff allows, never giving up. The
    /// change completes later; `away` is cleared once it reports success or the display is seen on.
    func restoreDisplay(_ state: inout PortState, port: String, reason: String) {
        guard let id = state.displayID, !inFlight.contains(port) else { return }
        let now = system.now
        if state.restore == nil {
            state.restore = Restore(reason: reason, next: now)
            log("\(state.identity?.name ?? "display") [\(port)] \(reason) -> enabling display \(id)")
        }
        guard let restore = state.restore, now >= restore.next else { return }
        guard !dryRun else { markOn(&state); return }
        inFlight.insert(port)
        system.setEnabled(id, true) { [weak self] ok in self?.restoreFinished(port: port, id: id, ok: ok) }
    }

    func restoreFinished(port: String, id: CGDirectDisplayID, ok: Bool) {
        inFlight.remove(port)
        guard var state = ports[port], var restore = state.restore else { return }
        if ok {
            if restore.attempts > 0 { log("display \(id) [\(port)] back on after \(restore.attempts + 1) attempts") }
            markOn(&state)
        } else {
            restore.attempts += 1
            let wait = Policy.restoreBackoff(attempts: restore.attempts)
            restore.next = system.now.addingTimeInterval(wait)
            state.restore = restore
            if restore.attempts == 1 || restore.attempts % 10 == 0 {
                log("could not enable display \(id) [\(port)] (attempt \(restore.attempts)); retrying in \(Int(wait))s")
            }
        }
        ports[port] = state
        saveState()
    }

    func markOn(_ state: inout PortState) {
        state.away = nil
        state.restore = nil
        state.restoreAfterWake = false
        state.turnedOnAt = system.now
        state.settleLogged = false
    }

    /// Starts a turn-off, mirror or unmirror; `finish` adjusts the port's state when it completes. A failure
    /// holds off further changes to that port with the same backoff as turning on.
    func change(port: String, what: String, _ start: (@escaping (Bool) -> Void) -> Void,
                finish: @escaping (inout PortState, Bool) -> Void) {
        guard !dryRun else { return }
        inFlight.insert(port)
        start { [weak self] ok in
            guard let self else { return }
            self.inFlight.remove(port)
            guard var state = self.ports[port] else { return }
            finish(&state, ok)
            if ok {
                state.nextChange = nil
                state.changeFailures = 0
            } else {
                state.changeFailures += 1
                let wait = Policy.restoreBackoff(attempts: state.changeFailures)
                state.nextChange = self.system.now.addingTimeInterval(wait)
                log("could not \(what) [\(port)]; next try in \(Int(wait))s at the earliest")
            }
            self.ports[port] = state
            self.saveState()
        }
    }

    func unmirror(_ state: inout PortState, port: String, id: CGDirectDisplayID) {
        log("stopping mirroring of display \(id)")
        guard !dryRun else { state.away = nil; return }
        change(port: port, what: "stop mirroring display \(id)", { self.system.setMirror(id, of: nil, completion: $0) }) { state, ok in
            if ok { state.away = nil }
        }
    }

    func hook(_ command: String?, event: String, monitor: String, port: String, input: Int?) {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !dryRun else { log("would run \(event) hook: \(command)"); return }
        system.runHook(command, event: event, monitor: monitor, port: port, input: input)
    }

    /// `onBack` runs once the monitor shows the Mac and whatever was done is undone.
    func runBackHookIfDue(_ state: inout PortState, monitor: MonitorConfig, port: String, input: Int) {
        guard state.hooksAway, input == monitor.macInput else { return }
        hook(monitor.onBack, event: "back", monitor: monitor.name, port: port, input: input)
        state.hooksAway = false
    }

    /// A monitor that is gone while away still gets its `onBack`, so hooks stay balanced (e.g. audio unmuted).
    func forgetHooks(_ state: inout PortState, port: String) {
        guard let monitor = state.identity.flatMap(config.monitor) else { state.hooksAway = false; return }
        hook(monitor.onBack, event: "back", monitor: monitor.name, port: port, input: nil)
        state.hooksAway = false
    }
}

public func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}
