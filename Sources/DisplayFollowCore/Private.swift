// Private Apple APIs. None of these are documented; a macOS update could change or remove them.
//
// They are looked up at runtime rather than linked, so a missing one makes the call fail (and `run` exit
// cleanly, see `PrivateAPI.missing`) instead of the binary failing to launch, and they are called with the
// C calling convention they actually have.
import CoreGraphics
import Foundation
import IOKit

enum PrivateAPI {
    static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: type)
    }

    typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    /// Enables or disables a display inside a display configuration transaction (SkyLight).
    static let configureDisplayEnabled = lookup("CGSConfigureDisplayEnabled", as: ConfigureDisplayEnabled.self)
    /// Apple Silicon DDC/CI transport (IOKit).
    static let avServiceCreate = lookup("IOAVServiceCreateWithService", as: AVServiceCreate.self)
    static let avServiceRead = lookup("IOAVServiceReadI2C", as: AVServiceI2C.self)
    static let avServiceWrite = lookup("IOAVServiceWriteI2C", as: AVServiceI2C.self)

    /// Names of the private functions this macOS doesn't have.
    static var missing: [String] {
        [("CGSConfigureDisplayEnabled", configureDisplayEnabled != nil), ("IOAVServiceCreateWithService", avServiceCreate != nil),
         ("IOAVServiceReadI2C", avServiceRead != nil), ("IOAVServiceWriteI2C", avServiceWrite != nil)]
            .filter { !$0.1 }.map(\.0)
    }
}

func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError {
    PrivateAPI.configureDisplayEnabled?(config, display, enabled) ?? .failure
}

func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>? {
    PrivateAPI.avServiceCreate?(allocator, service)
}

func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn {
    PrivateAPI.avServiceRead?(service, chip, offset, buf, len) ?? kIOReturnUnsupported
}

func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn {
    PrivateAPI.avServiceWrite?(service, chip, offset, buf, len) ?? kIOReturnUnsupported
}

/// CoreDisplay's per-display info; "IODisplayLocation" is the display's framebuffer path in the IORegistry.
typealias CoreDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
let coreDisplayCreateInfoDictionary: CoreDisplayInfoFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(symbol, to: CoreDisplayInfoFn.self)
}()
