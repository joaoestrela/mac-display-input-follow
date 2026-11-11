import Foundation

let usage = """
usage: display-follow <command>

  setup             save the external monitor and the Mac's current input to the config
  status            show the config and what the monitor reports now
  run [--dry-run]   watch the monitor and turn it off/on as its input changes
  list              list online displays (ID, vendor, model)
  input             read the external monitor's current input over DDC
  on <id>           turn a display on in software
  off <id>          turn a display off in software
  version           print the version
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "" : args.removeFirst()

switch command {
case "setup":
    guard let display = Displays.online().first(where: { !$0.builtin && $0.active }) else {
        fail("no active external display found")
    }
    guard let raw = DDC.read(DDC.inputSource) else {
        fail("\(Displays.name(display.id)) did not answer over DDC; enable DDC/CI in the monitor's menu")
    }
    var config = (try? ConfigStore.load()) ?? Config()
    let monitor = MonitorConfig(name: Displays.name(display.id), vendor: display.vendor, model: display.model,
                                serial: display.serial, macInput: DDCPacket.inputValue(raw))
    config.upsert(monitor)
    do { try ConfigStore.save(config) } catch { fail("could not write \(Paths.config.path): \(error)") }
    print("saved \(monitor.name) with Mac input \(monitor.macInput) to \(Paths.config.path)")
    print("run this while the Mac's input is showing; run it again if you move the Mac to another port")
case "status":
    print("config: \(Paths.config.path)")
    let config: Config?
    do { config = try ConfigStore.load() } catch { fail("invalid config: \(error)") }
    guard let config, !config.monitors.isEmpty else { fail("no monitors configured; run `display-follow setup`") }
    let input = DDC.read(DDC.inputSource).map(DDCPacket.inputValue)
    for monitor in config.monitors {
        let display = Displays.online().first { monitor.matches(vendor: $0.vendor, model: $0.model, serial: $0.serial) }
        let state = display.map { "display \($0.id), \($0.active ? "on" : "inactive")" } ?? "not listed (off or unplugged)"
        let showing = input.map { $0 == monitor.macInput ? "showing the Mac (input \($0))" : "on input \($0)" } ?? "no DDC reply"
        print("\(monitor.name): mac input \(monitor.macInput); \(state); \(showing)")
    }
case "run":
    Watcher(dryRun: args.contains("--dry-run")).run()
case "list":
    for d in Displays.online() {
        print("\(d.id) builtin=\(d.builtin) active=\(d.active) vendor=\(d.vendor) model=\(d.model) serial=\(d.serial)")
    }
case "input":
    guard let raw = DDC.read(DDC.inputSource) else { fail("ddc read failed") }
    print(DDCPacket.inputValue(raw))
case "on", "off":
    guard let id = args.first.flatMap(UInt32.init) else { fail("need a display id (see `display-follow list`)", code: 2) }
    guard Displays.setEnabled(id, command == "on") else { fail("could not turn display \(id) \(command)") }
case "version", "--version":
    print(version)
default:
    fail(usage, code: 2)
}
