import AppKit
import CoreGraphics
import Foundation

public final class Watcher {
    let configURL: URL
    let dryRun: Bool
    var config = Config()
    var configDate: Date?
    var timer: Timer?
    /// Per-port memory. A disabled display is no longer listed, so its ID (and identity) is remembered.
    struct PortState {
        var displayID: CGDirectDisplayID?
        var identity: MonitorIdentity?
        var isAway = false
        var confirmer = Confirmer()
        var lastReply = Date()
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
        for (port, id) in StateStore.load().off {
            ports[port] = PortState(displayID: id, isAway: true)
            log("display \(id) [\(port)] was turned off by a previous run")
        }
    }

    func saveState() {
        guard !dryRun else { return }
        let off = ports.compactMapValues { $0.isAway ? $0.displayID : nil }
        StateStore.save(RuntimeState(off: off))
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
        for (port, state) in ports where state.isAway && !connected.contains(where: { $0.port == port }) {
            if let id = state.displayID, !dryRun { Displays.setEnabled(id, true) }
            log("\(state.identity?.name ?? "display") [\(port)] disconnected while off; forgetting it")
        }

        for port in connected {
            var state = ports[port.port] ?? PortState()
            if let identity = port.identity { state.identity = identity }
            if let id = port.displayID {
                state.displayID = id
                // Listed again means it is on (re-plugged or turned on elsewhere); in a dry run it never went off.
                if !dryRun { state.isAway = false }
            }
            defer { seen[port.port] = state }
            guard let identity = state.identity, let monitor = config.monitor(identity), let id = state.displayID else { continue }

            let input = port.readInput()
            let now = Date()
            if input != nil { state.lastReply = now }
            if state.isAway, Policy.ddcLost(lastReply: state.lastReply, now: now, timeout: config.ddcLossTimeout) {
                log("\(monitor.name) [\(port.port)] silent over DDC for \(Int(config.ddcLossTimeout))s -> enabling display \(id)")
                if dryRun || Displays.setEnabled(id, true) { state.isAway = false; active += 1 }
                continue
            }
            let decision = Policy.decide(input: input, macInput: monitor.macInput, isAway: state.isAway,
                                         activeDisplays: active)
            switch state.confirmer.confirm(decision, required: config.confirmReads) {
            case .none:
                break
            case .away(let input):
                log("\(monitor.name) [\(port.port)] on input \(input) -> disabling display \(id)")
                if dryRun || Displays.setEnabled(id, false) { state.isAway = true; active -= 1 }
            case .back(let input):
                log("\(monitor.name) [\(port.port)] back on input \(input) -> enabling display \(id)")
                if dryRun || Displays.setEnabled(id, true) { state.isAway = false; active += 1 }
            }
        }
        ports = seen
    }
}

public func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}
