import Foundation
import IOKit

/// The system's power capabilities, as published by `IOPMrootDomain`. Read from the kernel on every
/// call, so it can't go stale like this process's own view of the displays.
public enum Power {
    /// `kIOPMSystemCapabilityGraphics` in IOKit/pwr_mgt/IOPM.h.
    static let graphicsCapability = 0x02

    /// True on a full wake, false while asleep or in a dark wake (a maintenance wake with the screens
    /// off), nil if the value can't be read.
    public static func hasGraphics() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "System Capabilities" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.intValue & graphicsCapability != 0
    }
}
