import Foundation

/// Makes sure only one watcher runs: two (say, `make install` and `brew services`) would fight over the
/// displays. The lock is held for the life of the process and released by the kernel when it exits.
public enum SingleInstance {
    static var lockFD: Int32 = -1

    /// `run.lock` next to the state file.
    public static var url: URL { StateStore.url.deletingLastPathComponent().appendingPathComponent("run.lock") }

    /// True if this process now holds the lock; false if another watcher does.
    public static func acquire() -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }  // can't lock: don't stop the watcher over it
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        lockFD = fd
        return true
    }
}
