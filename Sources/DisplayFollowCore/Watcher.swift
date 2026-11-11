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
    }
    var ports: [String: PortState] = [:]
    /// Set while the Mac or its displays sleep. DDC polling then could keep a monitor awake.
    var sleeping = false
    var resumeAt = Date.distantPast

    public init(configURL: URL = Paths.config, dryRun: Bool = false) {
        self.configURL = configURL
        self.dryRun = dryRun
    }

    public func run() -> Never {
        log("started (config \(configURL.path)\(dryRun ? ", dry run" : ""))")
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
                for key in self.ports.keys { self.ports[key]?.confirmer = Confirmer() }
                if self.sleeping { log("resuming in \(Int(self.config.wakeGrace))s (\(note.name.rawValue))") }
                self.sleeping = false
            }
        }
    }

    func tick() {
        reloadConfigIfChanged()
        guard !sleeping, Date() >= resumeAt else { return }
        var active = Displays.activeCount()
        var seen: [String: PortState] = [:]
        for port in Ports.external() {
            var state = ports[port.port] ?? PortState()
            if let identity = port.identity { state.identity = identity }
            if let id = port.displayID {
                state.displayID = id
                // Listed again means it is on (re-plugged or turned on elsewhere); in a dry run it never went off.
                if !dryRun { state.isAway = false }
            }
            defer { seen[port.port] = state }
            guard let identity = state.identity, let monitor = config.monitor(identity), let id = state.displayID else { continue }

            let decision = Policy.decide(input: port.readInput(), macInput: monitor.macInput, isAway: state.isAway,
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
