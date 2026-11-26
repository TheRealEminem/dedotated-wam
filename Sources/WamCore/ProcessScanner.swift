import Darwin
import Foundation

/// One process as the kernel reports it.
public struct ProcessEntry: Sendable, Equatable {
    public var pid: pid_t
    public var ppid: pid_t
    /// The process macOS holds responsible for this one (an app for its XPC helpers), or 0 if unknown.
    public var responsiblePid: pid_t
    /// Physical footprint in bytes: the "Memory" column in Activity Monitor.
    public var footprint: UInt64
    public var name: String

    public init(pid: pid_t, ppid: pid_t, responsiblePid: pid_t, footprint: UInt64, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.responsiblePid = responsiblePid
        self.footprint = footprint
        self.name = name
    }
}

public enum ProcessScanner {
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// Not in the public headers, but it is how the system attributes helpers such as browser tabs
    /// to their app. Looked up at run time so a missing symbol only costs accuracy.
    private static let responsiblePidFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// Every process this user is allowed to inspect. Other users' processes are skipped.
    public static func scan() -> [ProcessEntry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }

        var entries: [ProcessEntry] = []
        entries.reserveCapacity(Int(filled))
        var nameBuffer = [CChar](repeating: 0, count: 256)

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var usage = rusage_info_v4()
            let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard usageResult == 0 else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let ppid: pid_t = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize ? pid_t(bsd.pbi_ppid) : 0

            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0 ? String(cString: nameBuffer) : "pid \(pid)"

            entries.append(ProcessEntry(
                pid: pid,
                ppid: ppid,
                responsiblePid: responsiblePidFunction?(pid) ?? 0,
                footprint: usage.ri_phys_footprint,
                name: name
            ))
        }
        return entries
    }

    /// Rolls every process up into the app that owns it, so a browser is charged for its tabs.
    ///
    /// - Parameter units: pids of running apps, mapped to whether each is a regular (Dock) app.
    ///   A regular app always stands on its own. A background or menu bar app is folded into a
    ///   regular app above it when there is one, which is how Electron helpers end up with their parent.
    /// - Returns: total footprint per owning app pid.
    public static func footprintByApp(processes: [ProcessEntry], units: [pid_t: Bool]) -> [pid_t: UInt64] {
        var byPid: [pid_t: ProcessEntry] = [:]
        byPid.reserveCapacity(processes.count)
        for process in processes { byPid[process.pid] = process }

        var totals: [pid_t: UInt64] = [:]
        for process in processes {
            guard let owner = owner(of: process, byPid: byPid, units: units) else { continue }
            totals[owner, default: 0] += process.footprint
        }
        return totals
    }

    static func owner(of process: ProcessEntry, byPid: [pid_t: ProcessEntry], units: [pid_t: Bool]) -> pid_t? {
        if units[process.pid] == true { return process.pid }
        var best: pid_t? = units[process.pid] != nil ? process.pid : nil
        var current = process
        for _ in 0..<16 {
            let responsible = current.responsiblePid
            let next = (responsible > 1 && responsible != current.pid) ? responsible : current.ppid
            guard next > 1, next != current.pid else { break }
            if let isRegular = units[next] {
                best = next
                if isRegular { break }
            }
            guard let parent = byPid[next] else { break }
            current = parent
        }
        return best
    }
}
