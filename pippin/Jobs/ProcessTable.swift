import Darwin
import Foundation

/// Read-only lookups in the kernel process table (libproc). No subprocess.
public enum ProcessTable {
    /// When `pid` started, or nil if it is not running (or not ours to inspect).
    /// Comparing this with a recorded time tells a live process from a later
    /// one that was handed the same pid.
    public static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// Whether any process has exactly this name (`Mail`, `Notes`).
    public static func isRunning(named name: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if buffer.withUnsafeBufferPointer({ strcmp($0.baseAddress, name) == 0 }) { return true }
        }
        return false
    }
}
