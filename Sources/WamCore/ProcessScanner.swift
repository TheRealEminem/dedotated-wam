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

/// The app a process belongs to.
public struct ProcessOwner: Sendable, Equatable {
    public var name: String
    public var isFrontmost: Bool

    public init(name: String, isFrontmost: Bool) {
        self.name = name
        self.isFrontmost = isFrontmost
    }
}

/// One process on its own, not rolled up into its app, with what is needed to decide about it.
public struct RunningProcess: Sendable, Equatable, Identifiable {
    public var pid: pid_t
    public var name: String
    /// This process alone.
    public var footprint: UInt64
    /// This process plus everything it started, which is roughly what killing it frees.
    public var treeFootprint: UInt64
    public var ownerPid: pid_t?
    public var ownerName: String?
    public var isOwnerFrontmost: Bool
    /// True when this is the app's own main process rather than something inside it.
    public var isAppMain: Bool
    /// Part of the operating system, or this app itself.
    public var isProtected: Bool
    public var id: pid_t { pid }

    public init(
        pid: pid_t, name: String, footprint: UInt64, treeFootprint: UInt64, ownerPid: pid_t? = nil,
        ownerName: String? = nil, isOwnerFrontmost: Bool = false, isAppMain: Bool = false, isProtected: Bool = false
    ) {
        self.pid = pid
        self.name = name
        self.footprint = footprint
        self.treeFootprint = treeFootprint
        self.ownerPid = ownerPid
        self.ownerName = ownerName
        self.isOwnerFrontmost = isOwnerFrontmost
        self.isAppMain = isAppMain
        self.isProtected = isProtected
    }

    /// "node (in iTerm2)" for something inside an app, plain "Slack" for the app itself.
    public var displayName: String {
        if let ownerName, !isAppMain { return "\(name) (in \(ownerName))" }
        return name
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

    /// The executable's full path, or nil if it cannot be read.
    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Picks out the processes worth showing or acting on: the biggest ones, plus any whose name a
    /// rule mentions, each with its owning app and the memory of everything under it.
    ///
    /// - Parameters:
    ///   - owners: name and frontmost state of each app in `units`.
    ///   - ruleNames: lowercased process names that appear in triage rules.
    ///   - top: how many of the biggest processes to include regardless of rules.
    ///   - pathLookup: resolves a pid to its executable path; replaceable for tests.
    public static func describe(
        processes: [ProcessEntry],
        units: [pid_t: Bool],
        owners: [pid_t: ProcessOwner],
        ruleNames: Set<String>,
        top: Int,
        pathLookup: (pid_t) -> String? = ProcessScanner.path(of:)
    ) -> [RunningProcess] {
        var byPid: [pid_t: ProcessEntry] = [:]
        var children: [pid_t: [pid_t]] = [:]
        byPid.reserveCapacity(processes.count)
        for process in processes {
            byPid[process.pid] = process
            if process.ppid > 1, process.ppid != process.pid { children[process.ppid, default: []].append(process.pid) }
        }

        func treeFootprint(of root: pid_t) -> UInt64 {
            var total: UInt64 = 0
            var seen: Set<pid_t> = [root]
            var stack = [root]
            while let pid = stack.popLast() {
                total += byPid[pid]?.footprint ?? 0
                for child in children[pid] ?? [] where seen.insert(child).inserted { stack.append(child) }
            }
            return total
        }

        let sorted = processes.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
        var result: [RunningProcess] = []
        for (rank, process) in sorted.enumerated() {
            guard rank < top || ruleNames.contains(process.name.lowercased()) else { continue }
            let ownerPid = owner(of: process, byPid: byPid, units: units)
            let ownerInfo = ownerPid.flatMap { owners[$0] }
            result.append(RunningProcess(
                pid: process.pid,
                name: process.name,
                footprint: process.footprint,
                treeFootprint: treeFootprint(of: process.pid),
                ownerPid: ownerPid,
                ownerName: ownerInfo?.name,
                isOwnerFrontmost: ownerInfo?.isFrontmost ?? false,
                isAppMain: ownerPid == process.pid,
                isProtected: process.pid == getpid() || ProcessCatalog.isProtected(name: process.name, path: pathLookup(process.pid))
            ))
        }
        return result
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
