import Foundation

let usage = """
usage: display-follow <command>

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
case "run":
    var settings = WatcherSettings.fromEnvironment()
    settings.dryRun = args.contains("--dry-run")
    Watcher(settings: settings).run()
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
