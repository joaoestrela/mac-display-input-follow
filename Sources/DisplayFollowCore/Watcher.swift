import AppKit
import CoreGraphics
import Foundation

public final class Watcher {
    let configURL: URL
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
        var lastReply = Date()
        var isAway: Bool { away != nil }
    }
    var ports: [String: PortState] = [:]
    /// Set while the Mac or its displays sleep. DDC polling then could keep a monitor awake.
    var sleeping = false
    var resumeAt = Date.distantPast
    var signalSources: [DispatchSourceSignal] = []

    public init(configURL: URL = Paths.config, dryRun: Bool = false) {
        self.configURL = configURL
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
        let state = StateStore.load()
        for (port, id) in state.off {
            ports[port] = PortState(displayID: id, away: .off)
            log("display \(id) [\(port)] was turned off by a previous run")
        }
        for (port, id) in state.mirrored {
            ports[port] = PortState(displayID: id, away: .mirrored)
            log("display \(id) [\(port)] was mirrored by a previous run")
        }
    }

    func saveState() {
        guard !dryRun else { return }
        StateStore.save(RuntimeState(off: ports.compactMapValues { $0.away == .off ? $0.displayID : nil },
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
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, !self.sleeping else { return }
                self.sleeping = true
                log("paused (\(note.name.rawValue))")
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.resumeAt = Date().addingTimeInterval(self.config.wakeGrace)
                for key in self.ports.keys {
                    self.ports[key]?.confirmer = Confirmer()
                    // Time asleep is not DDC silence.
                    self.ports[key]?.lastReply = self.resumeAt
                }
                if self.sleeping { log("resuming in \(Int(self.config.wakeGrace))s (\(note.name.rawValue))") }
                self.sleeping = false
            }
        }
    }

    func tick() {
        reloadConfigIfChanged()
        guard !sleeping, Date() >= resumeAt else { return }
        defer { saveState() }
        var active = Displays.activeCount()
        var seen: [String: PortState] = [:]
        let connected = Ports.external()

        // A monitor unplugged while off: try to turn it on and forget it (macOS re-enables it on reconnect).
        for (port, state) in ports where state.away == .off && !connected.contains(where: { $0.port == port }) {
            if let id = state.displayID, !dryRun { Displays.setEnabled(id, true) }
            log("\(state.identity?.name ?? "display") [\(port)] disconnected while off; forgetting it")
        }

        for port in connected {
            var state = ports[port.port] ?? PortState()
            if let identity = port.identity { state.identity = identity }
            if let id = port.displayID { state.displayID = id }
            // Undone outside this tool (re-plugged, turned on, unmirrored): forget it. A dry run never changes anything.
            if !dryRun, let id = port.displayID,
               state.away == .off || (state.away == .mirrored && !Displays.isMirroring(id)) {
                state.away = nil
            }
            defer { seen[port.port] = state }
            guard let identity = state.identity else { continue }
            guard let monitor = config.monitor(identity) else {
                // Removed from the config while away: put the display back.
                if state.isAway, undo(&state, id: state.displayID) { active += 1 }
                continue
            }
            // Disabling or mirroring needs the display ID; hooks-only monitors don't.
            let id = state.displayID
            guard id != nil || monitor.action == .none || state.isAway else { continue }

            let input = port.readInput()
            let now = Date()
            if input != nil { state.lastReply = now }
            if state.isAway, Policy.ddcLost(lastReply: state.lastReply, now: now, timeout: config.ddcLossTimeout) {
                log("\(monitor.name) [\(port.port)] silent over DDC for \(Int(config.ddcLossTimeout))s -> restoring it")
                if undo(&state, id: id) { active += 1 }
                continue
            }
            let decision = Policy.decide(input: input, macInput: monitor.macInput, isAway: state.isAway,
                                         activeDisplays: active, needsOtherDisplay: monitor.action != .none)
            switch state.confirmer.confirm(decision, required: config.confirmReads) {
            case .none:
                break
            case .away(let input):
                let label = "\(monitor.name) [\(port.port)] on input \(input)"
                switch monitor.action {
                case .disable:
                    guard let id else { continue }
                    log("\(label) -> disabling display \(id)")
                    guard dryRun || Displays.setEnabled(id, false) else { log("could not disable display \(id)"); continue }
                    state.away = .off
                    active -= 1
                case .mirror:
                    guard let id, let target = Displays.mirrorTarget(for: id) else { continue }
                    log("\(label) -> mirroring display \(id) onto \(target)")
                    guard dryRun || Displays.setMirror(id, of: target) else { log("could not mirror display \(id)"); continue }
                    state.away = .mirrored
                case .none:
                    log("\(label)")
                    state.away = .hooksOnly
                }
                Hooks.run(monitor.onAway, event: "away", monitor: monitor.name, port: port.port, input: input, dryRun: dryRun)
            case .back(let input):
                log("\(monitor.name) [\(port.port)] back on input \(input)")
                if undo(&state, id: id) { active += 1 }
                Hooks.run(monitor.onBack, event: "back", monitor: monitor.name, port: port.port, input: input, dryRun: dryRun)
            }
        }
        ports = seen
    }

    /// Reverses whatever was done when the monitor went away. Returns true if a display was turned back on.
    func undo(_ state: inout PortState, id: CGDirectDisplayID?) -> Bool {
        guard let id, state.away == .off || state.away == .mirrored else {
            state.away = nil
            return false
        }
        switch state.away {
        case .off:
            log("enabling display \(id)")
            guard dryRun || Displays.setEnabled(id, true) else { log("could not enable display \(id)"); return false }
            state.away = nil
            return true
        case .mirrored:
            log("stopping mirroring of display \(id)")
            guard dryRun || Displays.setMirror(id, of: nil) else { log("could not stop mirroring display \(id)"); return false }
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
