import Darwin
import Foundation

// MARK: - Inputs and outputs

/// A running app, with the memory of all its helper processes added up.
public struct RunningApp: Sendable, Equatable, Identifiable {
    public var pid: pid_t
    public var bundleID: String?
    public var name: String
    public var footprint: UInt64
    public var isFrontmost: Bool
    /// True for apps that show in the Dock, false for menu bar and background apps.
    public var isRegular: Bool
    public var id: pid_t { pid }

    public init(pid: pid_t, bundleID: String?, name: String, footprint: UInt64, isFrontmost: Bool, isRegular: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.footprint = footprint
        self.isFrontmost = isFrontmost
        self.isRegular = isRegular
    }
}

public enum CloseMethod: String, Codable, Sendable {
    case polite
    case force

    public var verb: String { self == .polite ? "Quit" : "Force quit" }
}

/// An app that is eligible to be closed, and how its group says to close it.
public struct Candidate: Sendable, Equatable, Identifiable {
    public var app: RunningApp
    public var groupName: String
    public var action: CloseAction
    public var id: pid_t { app.pid }

    public init(app: RunningApp, groupName: String, action: CloseAction) {
        self.app = app
        self.groupName = groupName
        self.action = action
    }
}

public enum TriageStage: Int, Comparable, Sendable {
    case calm = 0
    /// Memory is tight: close apps nicely.
    case soft = 1
    /// Memory is critical: force quitting is allowed.
    case hard = 2

    public static func < (a: TriageStage, b: TriageStage) -> Bool { a.rawValue < b.rawValue }
}

public enum TriageDecision: Equatable, Sendable {
    case none
    case close(Candidate, CloseMethod)
    /// "Warn only" mode: what would have been closed.
    case wouldClose(Candidate, CloseMethod)
}

// MARK: - Planner

public enum TriagePlanner {
    public static let unlistedGroupName = "Unlisted"

    /// The stage memory is in right now, before any "must hold for N seconds" rule.
    public static func instantStage(settings: WamSettings, memory: MemorySample) -> TriageStage {
        let percent = memory.usedFraction * 100
        if settings.hardOnPressureCritical && memory.pressure >= .critical { return .hard }
        if settings.hardOnUsedPercent && percent >= Double(settings.hardUsedPercent) { return .hard }
        if settings.softOnPressureWarning && memory.pressure >= .warning { return .soft }
        if settings.softOnUsedPercent && percent >= Double(settings.softUsedPercent) { return .soft }
        if settings.softOnSwap && Double(memory.swapUsed) >= settings.softSwapGB * 1_073_741_824 { return .soft }
        return .calm
    }

    /// The order apps would be closed in: group by group, skipping anything protected.
    public static func queue(settings: WamSettings, apps: [RunningApp], selfBundleID: String?) -> [Candidate] {
        let minimum = UInt64(max(0, settings.minFootprintMB)) * 1_048_576
        let ownID = selfBundleID?.lowercased()

        // First group to list a bundle id owns it.
        var placement: [String: (group: Int, rule: Int)] = [:]
        for (groupIndex, group) in settings.groups.enumerated() {
            for (ruleIndex, rule) in group.apps.enumerated() {
                let key = rule.bundleID.lowercased()
                if placement[key] == nil { placement[key] = (groupIndex, ruleIndex) }
            }
        }

        func eligible(_ app: RunningApp) -> Bool {
            if app.pid == getpid() { return false }
            if let ownID, app.bundleID?.lowercased() == ownID { return false }
            if settings.protectFrontmost && app.isFrontmost { return false }
            return app.footprint >= minimum
        }

        var perGroup: [[(app: RunningApp, rule: Int)]] = Array(repeating: [], count: settings.groups.count)
        var unlisted: [RunningApp] = []
        for app in apps where eligible(app) {
            if let key = app.bundleID?.lowercased(), let place = placement[key] {
                perGroup[place.group].append((app, place.rule))
            } else if app.isRegular, app.bundleID.flatMap({ AppCatalog.classify(bundleID: $0, category: nil) }) != .never {
                // Not in any group. The catalog still gets a veto, so Finder and friends stay safe
                // even when "apps in no group" are allowed to be closed.
                unlisted.append(app)
            }
        }

        var result: [Candidate] = []
        for (index, group) in settings.groups.enumerated() where group.action != .never {
            let members: [(app: RunningApp, rule: Int)]
            switch group.order {
            case .listOrder:
                members = perGroup[index].sorted {
                    $0.rule != $1.rule ? $0.rule < $1.rule : $0.app.footprint > $1.app.footprint
                }
            case .largestFirst:
                members = perGroup[index].sorted {
                    $0.app.footprint != $1.app.footprint ? $0.app.footprint > $1.app.footprint : $0.app.pid < $1.app.pid
                }
            }
            result += members.map { Candidate(app: $0.app, groupName: group.name, action: group.action) }
        }
        if settings.unlistedPolicy == .lastResort {
            result += unlisted
                .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
                .map { Candidate(app: $0, groupName: unlistedGroupName, action: .polite) }
        }
        return result
    }
}

// MARK: - Engine

/// Decides, tick by tick, whether to close something. Holds the timing state between ticks.
public struct TriageEngine: Sendable {
    public private(set) var softSince: Date?
    public private(set) var hardSince: Date?
    public private(set) var lastActionAt: Date?
    /// Apps that were asked to quit nicely, and when.
    public private(set) var pendingPolite: [pid_t: Date] = [:]
    private var warnedThisEpisode = false

    public init() {}

    /// The stage after the "must hold for N seconds" rule.
    public func sustainedStage(now: Date, settings: WamSettings) -> TriageStage {
        // Critical memory is not given the full wait.
        let hardWait = min(settings.sustainSeconds, 5)
        if let hardSince, now.timeIntervalSince(hardSince) >= hardWait { return .hard }
        if let softSince, now.timeIntervalSince(softSince) >= settings.sustainSeconds { return .soft }
        return .calm
    }

    public mutating func tick(
        now: Date,
        settings: WamSettings,
        memory: MemorySample,
        apps: [RunningApp],
        selfBundleID: String?
    ) -> TriageDecision {
        let instant = TriagePlanner.instantStage(settings: settings, memory: memory)
        guard instant >= .soft else {
            softSince = nil
            hardSince = nil
            pendingPolite.removeAll()
            warnedThisEpisode = false
            return .none
        }
        if softSince == nil { softSince = now }
        if instant == .hard {
            if hardSince == nil { hardSince = now }
        } else {
            hardSince = nil
        }

        let stage = sustainedStage(now: now, settings: settings)
        guard stage >= .soft, settings.mode != .off else { return .none }

        let running = Set(apps.map(\.pid))
        pendingPolite = pendingPolite.filter { running.contains($0.key) }

        let cooldown = stage == .hard ? max(3, settings.cooldownSeconds / 3) : settings.cooldownSeconds
        if let lastActionAt, now.timeIntervalSince(lastActionAt) < cooldown { return .none }

        for candidate in TriagePlanner.queue(settings: settings, apps: apps, selfBundleID: selfBundleID) {
            let method: CloseMethod
            let askedAt = pendingPolite[candidate.app.pid]
            switch candidate.action {
            case .never:
                continue
            case .force:
                method = .force
            case .polite:
                // Already asked and still here: probably showing a save dialog. Move on.
                if askedAt != nil { continue }
                method = .polite
            case .politeThenForce:
                if let askedAt {
                    guard stage == .hard, now.timeIntervalSince(askedAt) >= settings.graceSeconds else { continue }
                    method = .force
                } else {
                    method = .polite
                }
            }

            if settings.mode == .notifyOnly {
                if warnedThisEpisode { return .none }
                warnedThisEpisode = true
                return .wouldClose(candidate, method)
            }
            lastActionAt = now
            if method == .polite {
                pendingPolite[candidate.app.pid] = now
            } else {
                pendingPolite[candidate.app.pid] = nil
            }
            return .close(candidate, method)
        }
        return .none
    }
}
