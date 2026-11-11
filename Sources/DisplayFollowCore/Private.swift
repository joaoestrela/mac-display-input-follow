// Private Apple APIs. None of these are documented; a macOS update could change them.
import CoreGraphics
import Foundation
import IOKit

/// Enables or disables a display inside a display configuration transaction (SkyLight).
@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

/// Apple Silicon DDC/CI transport (IOKit). Apple Silicon only.
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

/// CoreDisplay's per-display info; "IODisplayLocation" is the display's framebuffer path in the IORegistry.
typealias CoreDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
let coreDisplayCreateInfoDictionary: CoreDisplayInfoFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(symbol, to: CoreDisplayInfoFn.self)
}()
