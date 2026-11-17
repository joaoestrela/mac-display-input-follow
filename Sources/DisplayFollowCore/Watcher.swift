import AppKit
import CoreGraphics
import Foundation

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

    /// Per-port memory. A disabled display is no longer listed, so its ID (and identity) is remembered.
    struct PortState {
        var displayID: CGDirectDisplayID?
        var identity: MonitorIdentity?
        var away: AwayMode?
        var confirmer = Confirmer()
        var lastReply = Date.distantPast
        /// `onAway` ran and `onBack` has not yet. Survives the display being turned back on at wake.
        var hooksAway = false
        /// Set while the port is missing and the display is still off: when to try turning it on next.
        var nextRestoreTry: Date?
        /// When this tool last turned the display back on; see `Policy.settling`.
        var turnedOnAt: Date?
        var settleLogged = false
        var isAway: Bool { away != nil }
    }
    var ports: [String: PortState] = [:]
    /// Set while the Mac or its displays sleep. DDC polling then could keep a monitor awake.
    var sleeping = false
    var pausedAt = Date.distantPast
    /// Consecutive ticks that found every display asleep.
    var asleepReads = 0
    var resumeAt = Date.distantPast
    /// Ports whose display could not be turned back on at wake yet (macOS can refuse right after waking).
    var wakeRestorePending: [String: Int] = [:]
    let wakeRestoreAttempts = 30
    var signalSources: [DispatchSourceSignal] = []

    public init(system: System = RealSystem(), configURL: URL = Paths.config, config: Config? = nil, dryRun: Bool = false) {
        self.system = system
        self.configURL = configURL
        self.fixedConfig = config != nil
        self.config = config ?? Config()
        self.dryRun = dryRun
    }

    public func run() -> Never {
        log("started (config \(configURL.path)\(dryRun ? ", dry run" : ""))")
        if !dryRun { adoptState() }
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

    /// Picks up displays a previous run turned off, so they are still followed (and turned back on).
    func adoptState() {
        let state = system.loadState()
        for (port, id) in state.off {
            ports[port] = PortState(displayID: id, away: .off, lastReply: system.now, hooksAway: true)
            log("display \(id) [\(port)] was turned off by a previous run")
        }
        for (port, id) in state.mirrored {
            ports[port] = PortState(displayID: id, away: .mirrored, lastReply: system.now, hooksAway: true)
            log("display \(id) [\(port)] was mirrored by a previous run")
        }
    }

    func saveState() {
        guard !dryRun else { return }
        system.saveState(RuntimeState(off: ports.compactMapValues { $0.away == .off ? $0.displayID : nil },
                                     mirrored: ports.compactMapValues { $0.away == .mirrored ? $0.displayID : nil }))
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
    var pausedFor = PauseReason.system

    func pause(_ reason: String, for kind: PauseReason = .system) {
        guard !sleeping else { return }
        sleeping = true
        sawNoGraphics = false
        pausedFor = kind
        pausedAt = system.now
        log("paused (\(reason))")
    }

    func resume(_ reason: String) {
        resumeAt = system.now.addingTimeInterval(config.wakeGrace)
        for key in ports.keys {
            ports[key]?.confirmer = Confirmer()
            // Time asleep is not DDC silence.
            ports[key]?.lastReply = resumeAt
        }
        if sleeping {
            log("resuming in \(Int(config.wakeGrace))s (\(reason))")
            restoreForWake()
        }
        sleeping = false
    }

    let missingRetryInterval: TimeInterval = 15

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
            sawNoGraphics = true
            return false
        }
        if sleeping, pausedFor == .system {
            // Right after the will-sleep notification graphics still reads on: don't resume on that.
            guard graphics == true, sawNoGraphics || now.timeIntervalSince(pausedAt) > systemPauseMinimum else { return false }
            asleepReads = 0
            resume("full wake")
            return true
        }
        if !sleeping {
            asleepReads = system.anyDisplayAwake() ? 0 : asleepReads + 1
            guard asleepReads >= 2, now >= nextFreshCheck else { return true }
            nextFreshCheck = now.addingTimeInterval(freshCheckInterval)
            if system.freshAnyAwake() ?? false {
                if !loggedStaleView { log("displays read asleep here but awake in a fresh process; not pausing"); loggedStaleView = true }
            } else {
                pause("displays asleep", for: .displays)
            }
        } else if now >= nextFreshCheck {
            nextFreshCheck = now.addingTimeInterval(freshCheckInterval)
            if system.freshAnyAwake() ?? system.anyDisplayAwake() {
                asleepReads = 0
                resume("displays awake")
            }
        }
        return !sleeping
    }

    let freshCheckInterval: TimeInterval = 3
    /// A system-sleep pause is ended by graphics being on only after graphics was seen off, or after this long.
    let systemPauseMinimum: TimeInterval = 30
    var sawNoGraphics = false
    var nextFreshCheck = Date.distantPast
    var loggedStaleView = false

    /// While asleep the other source may have gone away (or the monitor been powered off and on).
    /// A monitor left on an input with no signal never comes back to the Mac by itself, because a
    /// display turned off sends no signal for its auto input-select to find. So turn every display
    /// back on at wake; after `wakeGrace` the watcher turns it off again if the other input is still in use.
    func restoreForWake() {
        wakeRestorePending = [:]
        for key in ports.keys where ports[key]?.away == .off || ports[key]?.away == .mirrored {
            log("\(ports[key]?.identity?.name ?? "display") [\(key)] turning back on after wake")
            wakeRestorePending[key] = 0
        }
        retryWakeRestore()
    }

    /// Runs every tick, also during `wakeGrace`, until each display is back on or the attempts run out.
    func retryWakeRestore() {
        guard !wakeRestorePending.isEmpty else { return }
        for (key, attempts) in wakeRestorePending {
            guard var state = ports[key], state.away == .off || state.away == .mirrored else {
                wakeRestorePending[key] = nil
                continue
            }
            _ = undo(&state, id: state.displayID, quiet: attempts > 0)
            ports[key] = state
            if !state.isAway {
                if attempts > 0 { log("display \(state.displayID.map(String.init) ?? "?") [\(key)] back on after \(attempts + 1) attempts") }
                wakeRestorePending[key] = nil
            } else if attempts + 1 >= wakeRestoreAttempts {
                log("giving up turning display \(state.displayID.map(String.init) ?? "?") [\(key)] back on; run `display-follow restore`")
                wakeRestorePending[key] = nil
            } else {
                wakeRestorePending[key] = attempts + 1
            }
        }
        saveState()
    }

    func tick() {
        reloadConfigIfChanged()
        guard followDisplaySleep() else { return }
        retryWakeRestore()
        guard system.now >= resumeAt else { return }
        defer { saveState() }
        var active = system.activeDisplayCount()
        var seen: [String: PortState] = [:]
        let connected = system.externalPorts()

        // A monitor that disappeared while off (unplugged, or its link dropped out briefly, e.g. in standby):
        // turn it back on and forget it only once that works. A display left off and forgotten would stay
        // off for good. A failed attempt can hang for seconds, so retry every `missingRetryInterval`.
        for (port, var state) in ports where state.away == .off && !connected.contains(where: { $0.port == port }) {
            let name = "\(state.identity?.name ?? "display") [\(port)]"
            guard let id = state.displayID, !dryRun else {
                log("\(name) disconnected while off; forgetting it")
                continue
            }
            if let next = state.nextRestoreTry, system.now < next {
                seen[port] = state
                continue
            }
            if system.setEnabled(id, true) {
                log("\(name) disconnected while off; turned display \(id) back on and forgot it")
                continue
            }
            if state.nextRestoreTry == nil {
                log("\(name) disconnected while off and display \(id) could not be turned on; retrying every \(Int(missingRetryInterval))s")
            }
            state.nextRestoreTry = system.now.addingTimeInterval(missingRetryInterval)
            seen[port] = state
        }

        for port in connected {
            var state = ports[port.port] ?? PortState(lastReply: system.now)
            state.nextRestoreTry = nil
            if let identity = port.identity { state.identity = identity }
            if let id = port.displayID { state.displayID = id }
            // Undone outside this tool (re-plugged, turned on, unmirrored): forget it. A dry run never changes anything.
            if !dryRun, let id = port.displayID,
               state.away == .off || (state.away == .mirrored && !system.isMirroring(id)) {
                state.away = nil
            }
            defer { seen[port.port] = state }
            // Still being turned back on after wake: judge its input once it is on.
            if wakeRestorePending[port.port] != nil { continue }
            guard let identity = state.identity else { continue }
            guard let monitor = config.monitor(identity) else {
                // Removed from the config while away: put the display back.
                if state.isAway, undo(&state, id: state.displayID) { active += 1 }
                continue
            }
            // Disabling or mirroring needs the display ID; hooks-only monitors don't.
            let id = state.displayID
            guard id != nil || monitor.action == .none || state.isAway else { continue }

            let input = system.readInput(port: port.port)
            let now = system.now
            if input != nil { state.lastReply = now }
            if state.isAway, Policy.ddcLost(lastReply: state.lastReply, now: now, timeout: config.ddcLossTimeout) {
                log("\(monitor.name) [\(port.port)] silent over DDC for \(Int(config.ddcLossTimeout))s -> restoring it")
                if undo(&state, id: id) { active += 1 }
                continue
            }
            var decision = Policy.decide(input: input, macInput: monitor.macInput, isAway: state.isAway,
                                         activeDisplays: active, needsOtherDisplay: monitor.action != .none)
            if case .away(let other) = decision, Policy.settling(turnedOnAt: state.turnedOnAt, now: now) {
                if !state.settleLogged {
                    state.settleLogged = true
                    log("\(monitor.name) [\(port.port)] reports input \(other) while settling after being turned on; ignoring")
                }
                decision = .none
            }
            switch state.confirmer.confirm(decision, required: config.confirmReads) {
            case .none:
                break
            case .away(let input):
                let label = "\(monitor.name) [\(port.port)] on input \(input)"
                switch monitor.action {
                case .disable:
                    guard let id else { continue }
                    log("\(label) -> disabling display \(id)")
                    guard dryRun || system.setEnabled(id, false) else { log("could not disable display \(id)"); continue }
                    state.away = .off
                    active -= 1
                case .mirror:
                    guard let id, let target = system.mirrorTarget(for: id) else { continue }
                    log("\(label) -> mirroring display \(id) onto \(target)")
                    guard dryRun || system.setMirror(id, of: target) else { log("could not mirror display \(id)"); continue }
                    state.away = .mirrored
                case .none:
                    log("\(label)")
                    state.away = .hooksOnly
                }
                // Already away before a wake restore: the hook has run.
                if !state.hooksAway {
                    hook(monitor.onAway, event: "away", monitor: monitor.name, port: port.port, input: input)
                    state.hooksAway = true
                }
            case .back(let input):
                log("\(monitor.name) [\(port.port)] back on input \(input)")
                if undo(&state, id: id) { active += 1 }
                runBackHook(&state, monitor: monitor, port: port.port, input: input)
            }
            // Turned back on at wake and found on the Mac's input: nothing to undo, but `onBack` is still due.
            if !state.isAway, state.hooksAway, let input, input == monitor.macInput {
                log("\(monitor.name) [\(port.port)] back on input \(input)")
                runBackHook(&state, monitor: monitor, port: port.port, input: input)
            }
        }
        ports = seen
    }

    func hook(_ command: String?, event: String, monitor: String, port: String, input: Int) {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !dryRun else { log("would run \(event) hook: \(command)"); return }
        system.runHook(command, event: event, monitor: monitor, port: port, input: input)
    }

    func runBackHook(_ state: inout PortState, monitor: MonitorConfig, port: String, input: Int) {
        guard state.hooksAway else { return }
        hook(monitor.onBack, event: "back", monitor: monitor.name, port: port, input: input)
        state.hooksAway = false
    }

    /// Reverses whatever was done when the monitor went away. Returns true if a display was turned back on.
    func undo(_ state: inout PortState, id: CGDirectDisplayID?, quiet: Bool = false) -> Bool {
        guard let id, state.away == .off || state.away == .mirrored else {
            state.away = nil
            return false
        }
        switch state.away {
        case .off:
            if !quiet { log("enabling display \(id)") }
            guard dryRun || system.setEnabled(id, true) else {
                if !quiet { log("could not enable display \(id)") }
                return false
            }
            state.away = nil
            state.turnedOnAt = system.now
            state.settleLogged = false
            return true
        case .mirrored:
            if !quiet { log("stopping mirroring of display \(id)") }
            guard dryRun || system.setMirror(id, of: nil) else {
                if !quiet { log("could not stop mirroring display \(id)") }
                return false
            }
            state.away = nil
            return false
        case .hooksOnly, nil:
            state.away = nil
            return false
        }
    }
}

public func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}
