import Foundation
import IOKit

/// DDC/CI over the Apple Silicon AV service. Keeps working while the display is disabled.
public enum DDC {
    /// VCP code for the active input source.
    public static let inputSource: UInt8 = 0x60

    static func externalAVService() -> CFTypeRef? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            let location = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc) {
                return av.takeRetainedValue()
            }
        }
        return nil
    }

    /// Reads a VCP feature's current value from the first external monitor.
    public static func read(_ code: UInt8, attempts: Int = 5) -> Int? {
        guard let av = externalAVService() else { return nil }
        for _ in 0..<attempts {
            var request = DDCPacket.getVCPRequest(code)
            _ = IOAVServiceWriteI2C(av, 0x37, 0x51, &request, UInt32(request.count))
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if IOAVServiceReadI2C(av, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               let value = DDCPacket.parseVCPReply(reply, code: code) {
                return value
            }
            usleep(40_000)
        }
        return nil
    }
}

/// DDC/CI packet encoding, kept free of IOKit so it can be checked offline.
public enum DDCPacket {
    public static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code, 0]
        packet[3] = 0x6E ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2]
        return packet
    }

    /// Returns the current value from a "VCP feature reply", or nil if it is malformed.
    public static func parseVCPReply(_ r: [UInt8], code: UInt8) -> Int? {
        guard r.count >= 12, r[2] == 0x02, r[3] == 0x00, r[4] == code else { return nil }
        var checksum: UInt8 = 0x50
        for byte in r[0..<11] { checksum ^= byte }
        guard checksum == r[11] else { return nil }
        return Int(r[8]) << 8 | Int(r[9])
    }

    /// Input source values carry the input in the low byte.
    public static func inputValue(_ raw: Int) -> Int { raw & 0xFF }
}
