import CoreGraphics
import Foundation

public struct WatcherSettings {
    public var macInput: Int
    public var vendor: UInt32
    public var model: UInt32
    public var interval: TimeInterval = 1
    public var dryRun = false

    /// Defaults are for an MSI MAG322UPF on HDMI 1; override with MAC_INPUT, VENDOR and MODEL.
    public static func fromEnvironment() -> WatcherSettings {
        let env = ProcessInfo.processInfo.environment
        return WatcherSettings(macInput: env["MAC_INPUT"].flatMap(Int.init) ?? 17,
                               vendor: env["VENDOR"].flatMap(UInt32.init) ?? 13929,
                               model: env["MODEL"].flatMap(UInt32.init) ?? 19911)
    }
}

public final class Watcher {
    let settings: WatcherSettings
    /// Last known ID of the monitor; a disabled display is no longer listed, so it is remembered.
    var displayID: CGDirectDisplayID?
    var isAway = false

    public init(settings: WatcherSettings) { self.settings = settings }

    public func run() -> Never {
        log("started (mac input \(settings.macInput)\(settings.dryRun ? ", dry run" : ""))")
        Timer.scheduledTimer(withTimeInterval: settings.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.run()
        exit(0)
    }

    func tick() {
        let online = Displays.online()
        if let monitor = online.first(where: { !$0.builtin && $0.vendor == settings.vendor && $0.model == settings.model }) {
            displayID = monitor.id
            // Listed again means it is on (re-plugged or turned on elsewhere); in a dry run it never went off.
            if !settings.dryRun { isAway = false }
        }
        guard let id = displayID else { return }
        let input = DDC.read(DDC.inputSource).map(DDCPacket.inputValue)
        switch Policy.decide(input: input, macInput: settings.macInput, isAway: isAway,
                             activeDisplays: online.filter(\.active).count) {
        case .none:
            break
        case .away(let input):
            log("monitor on input \(input) -> disabling display \(id)")
            if settings.dryRun || Displays.setEnabled(id, false) { isAway = true }
        case .back(let input):
            log("monitor back on input \(input) -> enabling display \(id)")
            if settings.dryRun || Displays.setEnabled(id, true) { isAway = false }
        }
    }
}

public func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}
