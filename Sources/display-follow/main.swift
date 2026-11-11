import Foundation

let usage = """
usage: display-follow <command>

  setup             save each external monitor and the Mac's current input to the config
  status            show each external monitor, its config and what it reports now
  run [--dry-run]   watch the monitors and turn them off/on as their inputs change
  list              list online displays (ID, vendor, model, port)
  input             read each external monitor's current input over DDC
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
    var config = (try? ConfigStore.load()) ?? Config()
    var saved = 0
    for port in Ports.external() {
        guard let identity = port.identity, port.displayID != nil else { continue }
        guard let input = port.readInput() else {
            print("skipped \(identity.name) [\(port.port)]: no DDC reply; enable DDC/CI in the monitor's menu")
            continue
        }
        config.upsert(MonitorConfig(identity, macInput: input))
        print("saved \(identity.name) [\(port.port)] with Mac input \(input)")
        saved += 1
    }
    guard saved > 0 else { fail("no external monitor answered over DDC") }
    do { try ConfigStore.save(config) } catch { fail("could not write \(Paths.config.path): \(error)") }
    print("wrote \(Paths.config.path)")
    print("run this while each monitor shows the Mac; run it again if you move the Mac to another port")
case "status":
    print("config: \(Paths.config.path)")
    let config: Config
    do { config = try ConfigStore.load() ?? Config() } catch { fail("invalid config: \(error)") }
    let ports = Ports.external()
    if ports.isEmpty { print("no external monitors connected") }
    for port in ports {
        let name = port.identity?.name ?? "unknown monitor"
        let state = port.displayID.map { "display \($0)" } ?? "display off or unavailable"
        let configured = port.identity.flatMap(config.monitor)
        let input = port.readInput()
        let showing: String
        switch (input, configured) {
        case (nil, _): showing = "no DDC reply"
        case (let input?, let monitor?): showing = input == monitor.macInput ? "showing the Mac (input \(input))" : "on input \(input)"
        case (let input?, nil): showing = "on input \(input)"
        }
        let mac = configured.map { "mac input \($0.macInput)" } ?? "not configured (run setup)"
        print("\(name) [\(port.port)]: \(mac); \(state); \(showing)")
    }
case "run":
    Watcher(dryRun: args.contains("--dry-run")).run()
case "list":
    let portByDisplay = Dictionary(Ports.external().compactMap { p in p.displayID.map { ($0, p.port) } },
                                   uniquingKeysWith: { first, _ in first })
    for d in Displays.online() {
        let port = d.builtin ? "builtin" : portByDisplay[d.id] ?? "?"
        print("\(d.id) builtin=\(d.builtin) active=\(d.active) vendor=\(d.vendor) model=\(d.model) serial=\(d.serial) port=\(port)")
    }
case "input":
    let ports = Ports.external()
    guard !ports.isEmpty else { fail("no external monitors connected") }
    var failed = false
    for port in ports {
        let label = "\(port.identity?.name ?? "unknown") [\(port.port)]"
        if let input = port.readInput() { print("\(label): \(input)") } else { print("\(label): no DDC reply"); failed = true }
    }
    if failed { exit(1) }
case "on", "off":
    guard let id = args.first.flatMap(UInt32.init) else { fail("need a display id (see `display-follow list`)", code: 2) }
    guard Displays.setEnabled(id, command == "on") else { fail("could not turn display \(id) \(command)") }
case "version", "--version":
    print(version)
default:
    fail(usage, code: 2)
}
