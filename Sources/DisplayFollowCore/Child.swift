import Foundation

/// Runs this same binary with other arguments. Display changes and display checks go through a child
/// process: a failing display change can hang for seconds, which would otherwise block the watcher (and
/// its stop handler), and a fresh process sees the current display state where a long-running one may not.
public enum Child {
    /// The binary to run, or nil if it is gone (e.g. replaced by an upgrade while running).
    static var executable: URL? {
        guard let url = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func makeProcess(_ arguments: [String]) -> Process? {
        guard let exe = executable else { return nil }
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs and waits up to `timeout` seconds without running the caller's run loop. Returns the exit
    /// status, or nil if it could not be run or timed out (it is then killed).
    public static func run(_ arguments: [String], timeout: TimeInterval) -> Int32? {
        guard let process = makeProcess(arguments) else { return nil }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            log("\(arguments.joined(separator: " ")) timed out after \(Int(timeout))s")
            return nil
        }
        return process.terminationStatus
    }

    /// Runs without waiting and calls `completion` on the main queue with the exit status, or nil if it
    /// could not be run or timed out (it is then killed).
    public static func start(_ arguments: [String], timeout: TimeInterval, completion: @escaping (Int32?) -> Void) {
        guard let process = makeProcess(arguments) else { completion(nil); return }
        var finished = false
        let finish: (Int32?) -> Void = { status in
            guard !finished else { return }
            finished = true
            completion(status)
        }
        process.terminationHandler = { p in DispatchQueue.main.async { finish(p.terminationStatus) } }
        do { try process.run() } catch { finish(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            process.terminate()
            log("\(arguments.joined(separator: " ")) timed out after \(Int(timeout))s")
            finish(nil)
        }
    }
}
