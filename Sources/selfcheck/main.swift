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
check(Policy.decide(input: 15, macInput: 17, isAway: false, activeDisplays: 1, needsOtherDisplay: false) == .away(input: 15),
      "hooks-only works with one display")

// DDC loss
let t0 = Date(timeIntervalSince1970: 1000)
check(!Policy.ddcLost(lastReply: t0, now: t0.addingTimeInterval(30), timeout: 30), "not lost at the limit")
check(Policy.ddcLost(lastReply: t0, now: t0.addingTimeInterval(31), timeout: 30), "lost after timeout")
check(!Policy.ddcLost(lastReply: t0, now: t0.addingTimeInterval(9999), timeout: 0), "timeout 0 disables")

// State
let both = RuntimeState(off: ["dispext1": 2], mirrored: ["dispext2": 3])
check((try? JSONDecoder().decode(RuntimeState.self, from: JSONEncoder().encode(both))) == both, "state round-trips")
check((try? JSONDecoder().decode(RuntimeState.self, from: Data(#"{"off":{"dispext1":2}}"#.utf8)))?.mirrored == [:],
      "older state file without mirrored")

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
check(defaults?.interval == 1 && defaults?.confirmReads == 2 && defaults?.wakeGrace == 5 && defaults?.ddcLossTimeout == 30,
      "defaults for missing keys")

// Actions and hooks
let withHooks = try? Config.decode(Data(#"{"monitors":[{"name":"M","vendor":1,"model":2,"serial":3,"macInput":17,"action":"mirror","onAway":"echo away"}]}"#.utf8))
check(withHooks?.monitors.first?.action == .mirror && withHooks?.monitors.first?.onAway == "echo away", "decodes action and hook")
let plain = try? Config.decode(Data(#"{"monitors":[{"name":"M","vendor":1,"model":2,"serial":3,"macInput":17}]}"#.utf8))
check(plain?.monitors.first?.action == .disable && plain?.monitors.first?.onBack == nil, "action defaults to disable")
check((try? Config.decode(Data(#"{"monitors":[{"name":"M","vendor":1,"model":2,"serial":3,"macInput":17,"action":"explode"}]}"#.utf8))) == nil,
      "rejects unknown action")
var keep = Config()
keep.upsert(MonitorConfig(name: "M", vendor: 1, model: 2, serial: 3, macInput: 17, action: .none, onAway: "a", onBack: "b"))
keep.upsert(MonitorConfig(name: "M", vendor: 1, model: 2, serial: 3, macInput: 15))
check(keep.monitors == [MonitorConfig(name: "M", vendor: 1, model: 2, serial: 3, macInput: 15, action: .none, onAway: "a", onBack: "b")],
      "setup keeps action and hooks")
check(Hooks.environment(event: "away", monitor: "M", port: "dispext1", input: 15)["DISPLAY_FOLLOW_INPUT"] == "15", "hook env")

// Port names
check(Ports.portName(inServicePath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/dcpext1@15C00000/AppleASCWrapV4/iop-dcpext1-nub/RTBuddy(DCPEXT1)/DCPEXT1Endpoint9/AFKDCPEXT1Endpoint9/AFKEPInterfaceServiceKextV2/dispext1:dcpav-service-epic:0/DCPAVServiceProxy") == "dispext1", "port from DDC service path")
check(Ports.portName(inServicePath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/dcp0@89C00000/AppleASCWrapV4/iop-dcp0-nub/RTBuddy(DCP0)/DCP0Endpoint9/AFKDCP0Endpoint9/AFKEPInterfaceServiceKextV2/disp0:dcpav-service-epic:0/DCPAVServiceProxy") == nil, "built-in has no external port")
check(Ports.portName(inFramebufferPath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/dispext1@14000000/IOMobileFramebufferShim") == "dispext1", "port from framebuffer path")
check(Ports.portName(inFramebufferPath: "IOService:/AppleARMPE/arm-io/AppleT602xIO/disp0@88000000/IOMobileFramebufferShim") == nil, "built-in framebuffer")
check(Ports.portName(inFramebufferPath: "IOService:/x/dispext10@1/IOMobileFramebufferShim") == "dispext10", "two-digit port")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
