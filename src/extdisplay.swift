// extdisplay: enable/disable a display in software (like unplugging it).
// Usage: extdisplay list | extdisplay on <id> | extdisplay off <id>
import CoreGraphics
import Foundation
import IOKit

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> Int32 {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return 1 }
    let err = CGSConfigureDisplayEnabled(cfg, id, on)
    guard err == .success else { CGCancelDisplayConfiguration(cfg); fputs("configure failed: \(err.rawValue)\n", stderr); return 1 }
    let done = CGCompleteDisplayConfiguration(cfg, .permanently)
    if done != .success { fputs("complete failed: \(done.rawValue)\n", stderr); return 1 }
    return 0
}

// --- DDC over Apple Silicon IOAVService (works even while the display is disabled) ---
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

func externalAVService() -> CFTypeRef? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc) { return av.takeRetainedValue() }
    }
    return nil
}

func readVCP(_ code: UInt8) -> Int? {
    guard let av = externalAVService() else { return nil }
    for _ in 0..<5 {
        var req: [UInt8] = [0x82, 0x01, code, 0]
        req[3] = 0x6E ^ 0x51 ^ req[0] ^ req[1] ^ req[2]
        _ = IOAVServiceWriteI2C(av, 0x37, 0x51, &req, 4)
        usleep(40_000)
        var r = [UInt8](repeating: 0, count: 12)
        if IOAVServiceReadI2C(av, 0x37, 0x51, &r, 12) == kIOReturnSuccess,
           r[2] == 0x02, r[3] == 0x00, r[4] == code {
            var x: UInt8 = 0x50; for b in r[0..<11] { x ^= b }
            if x == r[11] { return Int(r[8]) << 8 | Int(r[9]) }
        }
        usleep(40_000)
    }
    return nil
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "list":
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    for id in ids.prefix(Int(n)) {
        print("\(id) builtin=\(CGDisplayIsBuiltin(id) != 0) active=\(CGDisplayIsActive(id) != 0) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))")
    }
case "on", "off":
    guard args.count > 2, let id = UInt32(args[2]) else { fputs("need display id\n", stderr); exit(2) }
    exit(setEnabled(id, args[1] == "on"))
case "input":
    if let v = readVCP(0x60) { print(v & 0xFF) } else { fputs("ddc read failed\n", stderr); exit(1) }
default:
    fputs("usage: extdisplay list | on <id> | off <id>\n", stderr); exit(2)
}
