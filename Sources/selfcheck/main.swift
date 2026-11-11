// Offline checks for the pure logic. Run with `swift run selfcheck` (exit 1 on failure).
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(name)") }
}

// DDC packets
check(DDCPacket.getVCPRequest(0x60) == [0x82, 0x01, 0x60, 0xDC], "request checksum")  // 0x6E^0x51^0x82^0x01^0x60
func reply(_ code: UInt8, _ value: UInt16) -> [UInt8] {
    var r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, code, 0x00, 0x00, 0xFF, UInt8(value >> 8), UInt8(value & 0xFF), 0, 0]
    var c: UInt8 = 0x50; for b in r[0..<11] { c ^= b }; r[11] = c
    return r
}
check(DDCPacket.parseVCPReply(reply(0x60, 17), code: 0x60) == 17, "parses reply")
check(DDCPacket.parseVCPReply(reply(0x10, 17), code: 0x60) == nil, "rejects other VCP code")
var bad = reply(0x60, 17); bad[11] ^= 1
check(DDCPacket.parseVCPReply(bad, code: 0x60) == nil, "rejects bad checksum")
check(DDCPacket.inputValue(0x0F11) == 0x11, "input uses low byte")

// Policy
check(Policy.decide(input: 15, macInput: 17, isAway: false, activeDisplays: 2) == .away(input: 15), "switch away")
check(Policy.decide(input: 15, macInput: 17, isAway: false, activeDisplays: 1) == .none, "keeps last display")
check(Policy.decide(input: 15, macInput: 17, isAway: true, activeDisplays: 1) == .none, "already away")
check(Policy.decide(input: 17, macInput: 17, isAway: true, activeDisplays: 1) == .back(input: 17), "switch back")
check(Policy.decide(input: 17, macInput: 17, isAway: false, activeDisplays: 2) == .none, "steady on mac")
check(Policy.decide(input: nil, macInput: 17, isAway: true, activeDisplays: 1) == .none, "no reading")

// Confirmer
var confirmer = Confirmer()
check(confirmer.confirm(.away(input: 15), required: 2) == .none, "first read waits")
check(confirmer.confirm(.away(input: 15), required: 2) == .away(input: 15), "second identical read acts")
check(confirmer.confirm(.away(input: 15), required: 2) == .none, "resets after acting")
confirmer = Confirmer()
_ = confirmer.confirm(.away(input: 15), required: 2)
check(confirmer.confirm(.none, required: 2) == .none, "steady read clears pending")
check(confirmer.confirm(.away(input: 15), required: 2) == .none, "count restarted")
confirmer = Confirmer()
_ = confirmer.confirm(.away(input: 15), required: 3)
check(confirmer.confirm(.away(input: 16), required: 3) == .none, "different input restarts count")
var c1 = Confirmer()
check(c1.confirm(.back(input: 17), required: 1) == .back(input: 17), "required 1 acts at once")
var c0 = Confirmer()
check(c0.confirm(.back(input: 17), required: 0) == .back(input: 17), "required 0 treated as 1")

// Config
let msi = MonitorConfig(name: "MSI", vendor: 13929, model: 19911, serial: 16843009, macInput: 17)
var config = Config()
config.upsert(msi)
config.upsert(MonitorConfig(name: "MSI", vendor: 13929, model: 19911, serial: 16843009, macInput: 15))
check(config.monitors.count == 1 && config.monitors[0].macInput == 15, "upsert replaces the same monitor")
check(config.monitor(vendor: 13929, model: 19911, serial: 16843009) != nil, "finds monitor")
check(config.monitor(vendor: 13929, model: 19911, serial: 1) == nil, "serial must match")
check((try? Config.decode(config.encoded())) == config, "config round-trips")
let defaults = try? Config.decode(Data(#"{"monitors":[]}"#.utf8))
check(defaults?.interval == 1 && defaults?.confirmReads == 2 && defaults?.wakeGrace == 5, "defaults for missing keys")

// Port names
check(Ports.portName(inServicePath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/dcpext1@15C00000/AppleASCWrapV4/iop-dcpext1-nub/RTBuddy(DCPEXT1)/DCPEXT1Endpoint9/AFKDCPEXT1Endpoint9/AFKEPInterfaceServiceKextV2/dispext1:dcpav-service-epic:0/DCPAVServiceProxy") == "dispext1", "port from DDC service path")
check(Ports.portName(inServicePath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/dcp0@89C00000/AppleASCWrapV4/iop-dcp0-nub/RTBuddy(DCP0)/DCP0Endpoint9/AFKDCP0Endpoint9/AFKEPInterfaceServiceKextV2/disp0:dcpav-service-epic:0/DCPAVServiceProxy") == nil, "built-in has no external port")
check(Ports.portName(inFramebufferPath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/dispext1@14000000/IOMobileFramebufferShim") == "dispext1", "port from framebuffer path")
check(Ports.portName(inFramebufferPath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/disp0@88000000/IOMobileFramebufferShim") == nil, "built-in framebuffer")
check(Ports.portName(inFramebufferPath: "IOService:/x/dispext10@1/IOMobileFramebufferShim") == "dispext10", "two-digit port")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
