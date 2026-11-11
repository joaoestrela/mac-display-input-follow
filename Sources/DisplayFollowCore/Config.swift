import Foundation

/// What to do with a monitor while it shows another input.
public enum AwayAction: String, Codable, CaseIterable {
    /// Turn the display off in software; windows move to the remaining displays.
    case disable
    /// Mirror it onto another display (the built-in one if active); windows gather there.
    case mirror
    /// Leave the display alone; only run the hooks.
    case none
}

/// One monitor to follow. Identified by its EDID vendor, model and serial.
public struct MonitorConfig: Codable, Equatable {
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    /// Input source value (VCP 0x60, low byte) the monitor reports while showing this Mac.
    public var macInput: Int
    public var action: AwayAction = .disable
    /// Shell commands run when the monitor switches away from / back to the Mac.
    public var onAway: String?
    public var onBack: String?

    public init(name: String, vendor: UInt32, model: UInt32, serial: UInt32, macInput: Int,
                action: AwayAction = .disable, onAway: String? = nil, onBack: String? = nil) {
        self.name = name; self.vendor = vendor; self.model = model; self.serial = serial; self.macInput = macInput
        self.action = action; self.onAway = onAway; self.onBack = onBack
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decode(UInt32.self, forKey: .vendor)
        model = try c.decode(UInt32.self, forKey: .model)
        serial = try c.decode(UInt32.self, forKey: .serial)
        macInput = try c.decode(Int.self, forKey: .macInput)
        action = try c.decodeIfPresent(AwayAction.self, forKey: .action) ?? .disable
        onAway = try c.decodeIfPresent(String.self, forKey: .onAway)
        onBack = try c.decodeIfPresent(String.self, forKey: .onBack)
    }

    public init(_ identity: MonitorIdentity, macInput: Int) {
        self.init(name: identity.name, vendor: identity.vendor, model: identity.model, serial: identity.serial, macInput: macInput)
    }

    public func matches(vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        self.vendor == vendor && self.model == model && self.serial == serial
    }
}

public struct Config: Codable, Equatable {
    /// Seconds between DDC reads.
    public var interval: Double = 1
    /// Identical reads in a row needed before acting.
    public var confirmReads: Int = 2
    /// Seconds to wait after the Mac or its displays wake before acting; DDC is unreliable right after wake.
    public var wakeGrace: Double = 5
    /// Seconds without a DDC reply after which a monitor that was turned off is turned back on (0 = never).
    public var ddcLossTimeout: Double = 30
    public var monitors: [MonitorConfig] = []

    public init(interval: Double = 1, confirmReads: Int = 2, wakeGrace: Double = 5, ddcLossTimeout: Double = 30,
                monitors: [MonitorConfig] = []) {
        self.interval = interval; self.confirmReads = confirmReads; self.wakeGrace = wakeGrace
        self.ddcLossTimeout = ddcLossTimeout; self.monitors = monitors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 1
        confirmReads = try c.decodeIfPresent(Int.self, forKey: .confirmReads) ?? 2
        wakeGrace = try c.decodeIfPresent(Double.self, forKey: .wakeGrace) ?? 5
        ddcLossTimeout = try c.decodeIfPresent(Double.self, forKey: .ddcLossTimeout) ?? 30
        monitors = try c.decodeIfPresent([MonitorConfig].self, forKey: .monitors) ?? []
    }

    /// Adds a monitor, replacing any entry for the same physical monitor but keeping its action and hooks.
    public mutating func upsert(_ monitor: MonitorConfig) {
        var monitor = monitor
        if let old = self.monitor(vendor: monitor.vendor, model: monitor.model, serial: monitor.serial) {
            monitor.action = old.action; monitor.onAway = old.onAway; monitor.onBack = old.onBack
        }
        monitors.removeAll { $0.matches(vendor: monitor.vendor, model: monitor.model, serial: monitor.serial) }
        monitors.append(monitor)
    }

    public func monitor(vendor: UInt32, model: UInt32, serial: UInt32) -> MonitorConfig? {
        monitors.first { $0.matches(vendor: vendor, model: model, serial: serial) }
    }

    /// Identical monitors that report the same serial share one entry.
    public func monitor(_ identity: MonitorIdentity) -> MonitorConfig? {
        monitor(vendor: identity.vendor, model: identity.model, serial: identity.serial)
    }

    public static func decode(_ data: Data) throws -> Config { try JSONDecoder().decode(Config.self, from: data) }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `$XDG_CONFIG_HOME/display-follow/config.json`, defaulting to `~/.config`.
    public static var config: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("display-follow/config.json")
    }
}

public enum ConfigStore {
    public static func load(_ url: URL = Paths.config) throws -> Config? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Config.decode(Data(contentsOf: url))
    }

    public static func save(_ config: Config, to url: URL = Paths.config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.encoded().write(to: url, options: .atomic)
    }

    static func modificationDate(_ url: URL = Paths.config) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
