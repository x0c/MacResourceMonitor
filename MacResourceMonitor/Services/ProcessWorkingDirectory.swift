import Darwin
import Foundation

/// Current working directory of another process.
///
/// `PROC_PIDVNODEPATHINFO` needs no privilege for same-UID processes, so a menu-bar
/// app can tell parallel `pi` / `Cursor Agent` sessions apart by the folder they were
/// started in. Only queried for those few agent processes while a table is open.
nonisolated enum ProcessWorkingDirectory {
    static func read(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else {
            return nil
        }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }
}
