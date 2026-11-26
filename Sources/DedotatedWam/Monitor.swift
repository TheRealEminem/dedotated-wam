import AppKit
import Foundation
import UserNotifications
import WamCore

/// Everything the UI shows, captured at one moment.
struct Snapshot {
    static let historyLength = 60

    var cpu = CPUSample()
    var memory = MemorySample(total: MemorySampler.physicalMemory)
    /// Nil on Macs without a battery.
    var battery: BatterySample?
    /// Running apps, biggest first.
    var apps: [RunningApp] = []
    /// The biggest individual processes, plus any that a rule names.
    var processes: [RunningProcess] = []
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    /// Where memory is right now.
    var instantStage: TriageStage = .calm
    /// Where memory has been for long enough to act on.
    var stage: TriageStage = .calm
    /// What would be closed, in order.
    var queue: [Candidate] = []

    /// 0 calm, 1 tight, 2 critical. Drives the colour of the meters.
    var severity: Int {
        if memory.pressure >= .critical || instantStage == .hard { return 2 }
        if memory.pressure >= .warning || instantStage == .soft { return 1 }
        return 0
    }
}

/// Samples the system on its own high-priority queue and runs the triage engine there, so
/// closing apps does not depend on the UI being responsive.
final class Monitor: ObservableObject {
    @Published var snapshot = Snapshot()
    /// Called on the main thread after every sample.
    var onTick: ((Snapshot) -> Void)?

    private let store: SettingsStore
    private let log: ActivityLog
    private let queue = DispatchQueue(label: "com.dedotatedwam.monitor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var interval: Double = 0

    // Touched only on `queue`.
    private let cpuSampler = CPUSampler()
    private var engine = TriageEngine()
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var apps: [RunningApp] = []
    private var processes: [RunningProcess] = []
    private var lastAppScan = Date.distantPast
    private var lastFrontmost: pid_t = 0
    private var battery: BatterySample?
    private var lastBatteryRead = Date.distantPast
    private var detailed = false

    init(store: SettingsStore, log: ActivityLog) {
        self.store = store
        self.log = log
    }

    func start() {
        queue.async { [self] in
            _ = cpuSampler.sample() // Prime the tick counters.
            schedule(interval: store.current.refreshSeconds)
        }
    }

    /// While the popover is open the app list is refreshed on every tick.
    func setDetailed(_ value: Bool) {
        queue.async { [self] in
            detailed = value
            if value { tick() }
        }
    }

    private func schedule(interval newInterval: Double) {
        timer?.cancel()
        interval = max(0.5, newInterval)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.3, repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        let settings = store.current
        let now = Date()
        let cpu = cpuSampler.sample()
        let memory = MemorySampler.sample()

        // The battery moves slowly; reading it every few seconds is plenty.
        if now.timeIntervalSince(lastBatteryRead) >= 6 {
            battery = BatterySampler.sample()
            lastBatteryRead = now
        }

        cpuHistory.append(cpu.total)
        memoryHistory.append(memory.usedFraction)
        if cpuHistory.count > Snapshot.historyLength { cpuHistory.removeFirst(cpuHistory.count - Snapshot.historyLength) }
        if memoryHistory.count > Snapshot.historyLength { memoryHistory.removeFirst(memoryHistory.count - Snapshot.historyLength) }

        // Walking every process is the expensive part, so it only runs every tick when it matters.
        let instant = TriagePlanner.instantStage(settings: settings, memory: memory)
        if detailed || instant >= .soft || now.timeIntervalSince(lastAppScan) >= 6 {
            (apps, processes) = scan(settings: settings)
            lastAppScan = now
        }

        let decision = engine.tick(now: now, settings: settings, memory: memory, apps: apps, processes: processes, selfBundleID: AppPaths.bundleID)
        act(on: decision, memory: memory, settings: settings)

        let snapshot = Snapshot(
            cpu: cpu,
            memory: memory,
            battery: battery,
            apps: apps,
            processes: processes,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            instantStage: instant,
            stage: engine.sustainedStage(now: now, settings: settings),
            queue: TriagePlanner.queue(settings: settings, apps: apps, processes: processes, selfBundleID: AppPaths.bundleID)
        )
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = snapshot
            self?.onTick?(snapshot)
        }

        if settings.refreshSeconds != interval, settings.refreshSeconds >= 0.5 {
            schedule(interval: settings.refreshSeconds)
        }
    }

    /// Apps only, for callers that do not need the per-process view.
    func scanApps() -> [RunningApp] {
        scan(settings: store.current).apps
    }

    /// One pass over every process, read two ways: rolled up into apps, and one by one.
    func scan(settings: WamSettings) -> (apps: [RunningApp], processes: [RunningProcess]) {
        let running = NSWorkspace.shared.runningApplications
        let ownPid = ProcessInfo.processInfo.processIdentifier
        // When our own popover is in front, the app the user was just in is the one to protect.
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != ownPid {
            lastFrontmost = front
        }

        var units: [pid_t: Bool] = [:]
        for app in running where app.activationPolicy != .prohibited {
            units[app.processIdentifier] = app.activationPolicy == .regular
        }
        let entries = ProcessScanner.scan()
        let totals = ProcessScanner.footprintByApp(processes: entries, units: units)

        var apps: [RunningApp] = []
        var owners: [pid_t: ProcessOwner] = [:]
        apps.reserveCapacity(totals.count)
        for app in running {
            let pid = app.processIdentifier
            guard let footprint = totals[pid] else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            owners[pid] = ProcessOwner(name: name, isFrontmost: pid == lastFrontmost)
            apps.append(RunningApp(
                pid: pid,
                bundleID: app.bundleIdentifier,
                name: name,
                footprint: footprint,
                isFrontmost: pid == lastFrontmost,
                isRegular: app.activationPolicy == .regular
            ))
        }
        apps.sort { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }

        var ruleNames = Set<String>()
        for group in settings.groups {
            for rule in group.apps {
                if let name = rule.processName { ruleNames.insert(name.lowercased()) }
            }
        }
        let processes = ProcessScanner.describe(processes: entries, units: units, owners: owners, ruleNames: ruleNames, top: 40)
        return (apps, processes)
    }

    private func act(on decision: TriageDecision, memory: MemorySample, settings: WamSettings) {
        let reading = "\(memory.usedPercent)% used, pressure \(memory.pressure.label.lowercased())"
        switch decision {
        case .none:
            return
        case .close(let candidate, let method):
            let succeeded = Closer.close(pid: candidate.app.pid, method: method)
            log.add(LogEntry(
                kind: .auto,
                appName: candidate.app.name,
                bundleID: candidate.app.bundleID,
                method: method,
                succeeded: succeeded,
                footprint: candidate.app.footprint,
                detail: "\(reading). Group: \(candidate.groupName)."
            ))
            if settings.notify {
                Notifier.post(
                    title: "\(method.verb) \(candidate.app.name)",
                    body: "Memory was running short (\(reading)). It was using \(ByteFormat.string(candidate.app.footprint))."
                )
            }
        case .wouldClose(let candidate, let method):
            log.add(LogEntry(
                kind: .wouldClose,
                appName: candidate.app.name,
                bundleID: candidate.app.bundleID,
                method: method,
                succeeded: true,
                footprint: candidate.app.footprint,
                detail: "\(reading). Warn only, nothing was closed."
            ))
            if settings.notify {
                Notifier.post(
                    title: "Memory is running short",
                    body: "\(reading). First to go would be \(candidate.app.name) (\(ByteFormat.string(candidate.app.footprint))). Auto-close is set to warn only."
                )
            }
        }
    }
}

// MARK: - Closing

enum Closer {
    /// Returns true if the request was delivered. A polite quit can still be refused by the app.
    @discardableResult
    static func close(pid: pid_t, method: CloseMethod) -> Bool {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let app = NSRunningApplication(processIdentifier: pid)
        switch method {
        case .polite:
            return app?.terminate() ?? (kill(pid, SIGTERM) == 0)
        case .force:
            if app?.forceTerminate() == true { return true }
            return kill(pid, SIGKILL) == 0
        }
    }
}

// MARK: - Notifications

enum Notifier {
    /// Notifications need a real app bundle; running the bare binary skips them.
    private static let available = Bundle.main.bundleIdentifier != nil

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
