import Foundation

/// Keeps the log from growing without bound. launchd (or `brew services`) points stdout and stderr at the
/// log file; when it grows past `maxBytes` it is moved to `<log>.1` (replacing the previous one) and output
/// continues in a new file at the same path.
public enum LogFile {
    public static let maxBytes = 5 * 1024 * 1024

    /// The file stdout writes to, if it is a regular file.
    static var path: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(STDOUT_FILENO, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(cString: buffer)
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return path
    }

    public static func rotateIfNeeded() {
        guard let path, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > maxBytes else { return }
        fflush(stdout)
        let old = path + ".1"
        try? FileManager.default.removeItem(atPath: old)
        guard (try? FileManager.default.moveItem(atPath: path, toPath: old)) != nil,
              freopen(path, "a", stdout) != nil else { return }
        dup2(STDOUT_FILENO, STDERR_FILENO)
        log("rotated the log; the previous one is \(old)")
    }
}
