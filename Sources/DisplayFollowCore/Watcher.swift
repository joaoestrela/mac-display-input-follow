import CoreGraphics
import Foundation

public final class Watcher {
    let configURL: URL
    let dryRun: Bool
    var config = Config()
    var configDate: Date?
    var timer: Timer?
    /// Last known ID of the monitor; a disabled display is no longer listed, so it is remembered.
    var displayID: CGDirectDisplayID?
    var monitor: MonitorConfig?
    var isAway = false

    public init(configURL: URL = Paths.config, dryRun: Bool = false) {
        self.configURL = configURL
        self.dryRun = dryRun
    }

    public func run() -> Never {
        log("started (config \(configURL.path)\(dryRun ? ", dry run" : ""))")
        reloadConfigIfChanged()
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

    func tick() {
        reloadConfigIfChanged()
        let online = Displays.online()
        if let display = online.first(where: { !$0.builtin }),
           let configured = config.monitor(vendor: display.vendor, model: display.model, serial: display.serial) {
            displayID = display.id
            monitor = configured
            // Listed again means it is on (re-plugged or turned on elsewhere); in a dry run it never went off.
            if !dryRun { isAway = false }
        }
        guard let id = displayID, let monitor else { return }
        let input = DDC.read(DDC.inputSource).map(DDCPacket.inputValue)
        switch Policy.decide(input: input, macInput: monitor.macInput, isAway: isAway,
                             activeDisplays: online.filter(\.active).count) {
        case .none:
            break
        case .away(let input):
            log("\(monitor.name) on input \(input) -> disabling display \(id)")
            if dryRun || Displays.setEnabled(id, false) { isAway = true }
        case .back(let input):
            log("\(monitor.name) back on input \(input) -> enabling display \(id)")
            if dryRun || Displays.setEnabled(id, true) { isAway = false }
        }
    }
}

public func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}
