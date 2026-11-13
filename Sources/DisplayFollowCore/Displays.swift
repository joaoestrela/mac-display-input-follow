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

    /// True if any active display is awake. Used to notice a wake whose notification never came.
    public static func anyAwake() -> Bool { online().contains { $0.active && CGDisplayIsAsleep($0.id) == 0 } }

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

    /// Mirrors `id` onto `target`, or stops mirroring when `target` is nil.
    @discardableResult
    public static func setMirror(_ id: CGDirectDisplayID, of target: CGDirectDisplayID?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(cfg, id, target ?? kCGNullDirectDisplay) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    public static func isMirroring(_ id: CGDirectDisplayID) -> Bool { CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay }

    /// Where to mirror `id`: the built-in display if active, otherwise another active display.
    public static func mirrorTarget(for id: CGDirectDisplayID) -> CGDirectDisplayID? {
        let others = online().filter { $0.active && $0.id != id && !isMirroring($0.id) }
        return (others.first(where: \.builtin) ?? others.first)?.id
    }
}
