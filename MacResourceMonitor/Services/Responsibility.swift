import Darwin
import Foundation

nonisolated enum Responsibility {
    private typealias GetResponsiblePID = @convention(c) (pid_t) -> pid_t

    static func pidResponsible(for pid: pid_t) -> pid_t {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "responsibility_get_pid_responsible_for_pid") else {
            return pid
        }
        let function = unsafeBitCast(symbol, to: GetResponsiblePID.self)
        let responsible = function(pid)
        return responsible > 0 ? responsible : pid
    }
}
