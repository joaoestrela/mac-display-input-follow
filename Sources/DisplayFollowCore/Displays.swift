import AppKit
import CoreGraphics

public struct DisplayInfo {
    public let id: CGDirectDisplayID
    public let builtin: Bool
    public let active: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
}

public enum Displays {
    /// Online displays. A display disabled in software is not listed.
    public static func online() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(id: id, builtin: CGDisplayIsBuiltin(id) != 0, active: CGDisplayIsActive(id) != 0,
                        vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                        serial: CGDisplaySerialNumber(id))
        }
    }

    /// Human-readable name, e.g. "MSI MAG322UPF".
    public static func name(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?
            .localizedName ?? "Display \(id)"
    }

    public static func activeCount() -> Int { online().filter(\.active).count }

    /// Turns a display on or off in software, as if it were plugged in or unplugged.
    @discardableResult
    public static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        guard CGSConfigureDisplayEnabled(cfg, id, enabled) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }
}
