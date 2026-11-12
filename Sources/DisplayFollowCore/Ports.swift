import CoreGraphics
import Foundation
import IOKit

/// An external display connection: its DDC service, the monitor's identity and (if on) its display ID.
///
/// On Apple Silicon each external connection has a DCP "port" named `dispextN`. The same name appears in
/// the DDC service's registry path (`dispextN:dcpav-service-epic`), the framebuffer's path (`dispextN@...`)
/// and CoreDisplay's `IODisplayLocation`, which is how the three are matched.
public struct ExternalPort {
    public let port: String
    let avService: CFTypeRef
    /// Monitor identity from the framebuffer's EDID attributes; nil if unavailable.
    public let identity: MonitorIdentity?
    /// Display ID while the display is online; a display disabled in software is not listed.
    public let displayID: CGDirectDisplayID?

    public func readInput() -> Int? { DDC.read(DDC.inputSource, service: avService).map(DDCPacket.inputValue) }
}

public struct MonitorIdentity: Equatable {
    public let name: String
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
}

public enum Ports {
    public static func external() -> [ExternalPort] {
        let framebuffers = framebufferIdentities()
        let displays = onlineDisplayPorts()
        return services(matching: "DCPAVServiceProxy") { svc, path -> ExternalPort? in
            let location = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let port = portName(inServicePath: path),
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc)?.takeRetainedValue() else { return nil }
            return ExternalPort(port: port, avService: av, identity: framebuffers[port], displayID: displays[port])
        }.sorted { $0.port < $1.port }
    }

    /// "…/dispext1:dcpav-service-epic:0/DCPAVServiceProxy" -> "dispext1"
    public static func portName(inServicePath path: String) -> String? {
        guard let range = path.range(of: #"dispext\d+(?=:dcpav-service-epic)"#, options: .regularExpression) else { return nil }
        return String(path[range])
    }

    /// "…/AppleT602xIO/dispext1@14000000/IOMobileFramebufferShim" -> "dispext1"
    public static func portName(inFramebufferPath path: String) -> String? {
        guard let range = path.range(of: #"(?<=/)dispext\d+(?=@)"#, options: .regularExpression) else { return nil }
        return String(path[range])
    }

    static func framebufferIdentities() -> [String: MonitorIdentity] {
        let pairs = services(matching: "IOMobileFramebufferShim") { svc, path -> (String, MonitorIdentity)? in
            guard let port = portName(inFramebufferPath: path),
                  let attrs = IORegistryEntryCreateCFProperty(svc, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let product = attrs["ProductAttributes"] as? [String: Any],
                  let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                  let model = (product["ProductID"] as? NSNumber)?.uint32Value
            else { return nil }
            return (port, MonitorIdentity(name: product["ProductName"] as? String ?? "Display on \(port)",
                                          vendor: vendor, model: model,
                                          serial: (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0))
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    static func onlineDisplayPorts() -> [String: CGDirectDisplayID] {
        guard let info = coreDisplayCreateInfoDictionary else { return [:] }
        var result: [String: CGDirectDisplayID] = [:]
        for display in Displays.online() where !display.builtin {
            guard let dict = info(display.id)?.takeRetainedValue() as? [String: Any],
                  let location = dict["IODisplayLocation"] as? String,
                  let port = portName(inFramebufferPath: location) else { continue }
            result[port] = display.id
        }
        return result
    }

    /// Calls `body` for each matching service with its IOService-plane path, releasing the service afterwards.
    static func services<T>(matching className: String, _ body: (io_service_t, String) -> T?) -> [T] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var result: [T] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            var buffer = [CChar](repeating: 0, count: 1024)
            IORegistryEntryGetPath(svc, kIOServicePlane, &buffer)
            if let value = body(svc, String(cString: buffer)) { result.append(value) }
        }
        return result
    }
}
