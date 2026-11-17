import Foundation

/// Runs a monitor's `onAway`/`onBack` command with `/bin/sh -c`, without waiting for it.
///
/// Environment: DISPLAY_FOLLOW_EVENT (away|back), DISPLAY_FOLLOW_MONITOR, DISPLAY_FOLLOW_PORT, DISPLAY_FOLLOW_INPUT.
public enum Hooks {
    /// `input` is nil for a `back` sent because the monitor is gone; DISPLAY_FOLLOW_INPUT is then empty.
    public static func environment(event: String, monitor: String, port: String, input: Int?) -> [String: String] {
        ["DISPLAY_FOLLOW_EVENT": event, "DISPLAY_FOLLOW_MONITOR": monitor,
         "DISPLAY_FOLLOW_PORT": port, "DISPLAY_FOLLOW_INPUT": input.map(String.init) ?? ""]
    }

    static func run(_ command: String?, event: String, monitor: String, port: String, input: Int?) {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment(event: event, monitor: monitor, port: port, input: input)) { _, new in new }
        process.terminationHandler = { p in
            if p.terminationStatus != 0 { log("\(event) hook exited with \(p.terminationStatus): \(command)") }
        }
        do { try process.run() } catch { log("could not run \(event) hook: \(error)") }
    }
}
