import Foundation

// MARK: - Choices

/// How a group's apps may be closed.
public enum CloseAction: String, Codable, CaseIterable, Sendable {
    /// Ask the app to quit, and leave it alone if it refuses (for example, it is asking to save).
    case polite
    /// Ask first. If it is still running after the grace period and memory is critical, force quit.
    case politeThenForce
    /// Force quit straight away. Unsaved work in the app is lost.
    case force
    /// Never close automatically.
    case never

    public var label: String {
        switch self {
        case .polite: return "Quit nicely only"
        case .politeThenForce: return "Quit nicely, force if stuck"
        case .force: return "Force quit immediately"
        case .never: return "Never close"
        }
    }
}

public enum GroupOrder: String, Codable, CaseIterable, Sendable {
    /// Close in the order the apps are listed.
    case listOrder
    /// Close whichever is using the most memory first.
    case largestFirst

    public var label: String {
        switch self {
        case .listOrder: return "In list order"
        case .largestFirst: return "Biggest first"
        }
    }
}

public enum AutoCloseMode: String, Codable, CaseIterable, Sendable {
    case off
    /// Works out what it would close and tells you, but touches nothing.
    case notifyOnly
    case armed

    public var label: String {
        switch self {
        case .off: return "Off"
        case .notifyOnly: return "Warn only"
        case .armed: return "Auto-close"
        }
    }
}

/// What to do about running apps that are in no group.
public enum UnlistedPolicy: String, Codable, CaseIterable, Sendable {
    case ignore
    /// After every group is exhausted, ask them to quit nicely, biggest first.
    case lastResort

    public var label: String {
        switch self {
        case .ignore: return "Leave them alone"
        case .lastResort: return "Quit nicely after all groups"
        }
    }
}

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case full
    case graphs
    case compact

    public var label: String {
        switch self {
        case .full: return "Graphs and numbers"
        case .graphs: return "Graphs only"
        case .compact: return "Compact stacked bars"
        }
    }
}

public enum CPUGraphStyle: String, Codable, CaseIterable, Sendable {
    case history
    case cores

    public var label: String {
        switch self {
        case .history: return "Recent history"
        case .cores: return "One bar per core"
        }
    }
}

// MARK: - Groups

public struct AppRule: Codable, Identifiable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A named set of apps that are closed together, in order, before the next group is touched.
public struct TriageGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var action: CloseAction
    public var order: GroupOrder
    public var apps: [AppRule]

    public init(id: UUID = UUID(), name: String, action: CloseAction, order: GroupOrder, apps: [AppRule] = []) {
        self.id = id
        self.name = name
        self.action = action
        self.order = order
        self.apps = apps
    }
}

/// An app found on disk.
public struct InstalledApp: Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var category: String?
    public var path: String

    public init(bundleID: String, name: String, category: String?, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.category = category
        self.path = path
    }
}

// MARK: - Settings

public struct WamSettings: Codable, Equatable, Sendable {
    // Display
    public var refreshSeconds: Double = 2
    public var menuBarStyle: MenuBarStyle = .full
    public var cpuGraphStyle: CPUGraphStyle = .history
    public var colorByPressure: Bool = true
    /// Adds a battery meter, so the system's own battery icon can be switched off.
    public var showBattery: Bool = true

    // Auto-close
    public var mode: AutoCloseMode = .off
    /// Stage one (close nicely) starts when macOS reports memory pressure "warning".
    public var softOnPressureWarning: Bool = true
    public var softOnUsedPercent: Bool = true
    public var softUsedPercent: Int = 92
    public var softOnSwap: Bool = false
    public var softSwapGB: Double = 6
    /// Stage two (force quit allowed) starts when macOS reports "critical".
    public var hardOnPressureCritical: Bool = true
    public var hardOnUsedPercent: Bool = true
    public var hardUsedPercent: Int = 97
    /// How long the condition must hold before anything is closed.
    public var sustainSeconds: Double = 10
    /// Pause after closing an app, so memory can settle before the next one is judged.
    public var cooldownSeconds: Double = 15
    /// How long an app gets to quit nicely before it may be force quit.
    public var graceSeconds: Double = 20
    public var protectFrontmost: Bool = true
    /// Apps using less than this are not worth closing.
    public var minFootprintMB: Int = 100
    public var unlistedPolicy: UnlistedPolicy = .ignore
    public var notify: Bool = true

    public var groups: [TriageGroup] = []
    /// False until the groups have been filled from the catalog on first launch.
    public var seeded: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WamSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        refreshSeconds = value(.refreshSeconds, defaults.refreshSeconds)
        menuBarStyle = value(.menuBarStyle, defaults.menuBarStyle)
        cpuGraphStyle = value(.cpuGraphStyle, defaults.cpuGraphStyle)
        colorByPressure = value(.colorByPressure, defaults.colorByPressure)
        showBattery = value(.showBattery, defaults.showBattery)
        mode = value(.mode, defaults.mode)
        softOnPressureWarning = value(.softOnPressureWarning, defaults.softOnPressureWarning)
        softOnUsedPercent = value(.softOnUsedPercent, defaults.softOnUsedPercent)
        softUsedPercent = value(.softUsedPercent, defaults.softUsedPercent)
        softOnSwap = value(.softOnSwap, defaults.softOnSwap)
        softSwapGB = value(.softSwapGB, defaults.softSwapGB)
        hardOnPressureCritical = value(.hardOnPressureCritical, defaults.hardOnPressureCritical)
        hardOnUsedPercent = value(.hardOnUsedPercent, defaults.hardOnUsedPercent)
        hardUsedPercent = value(.hardUsedPercent, defaults.hardUsedPercent)
        sustainSeconds = value(.sustainSeconds, defaults.sustainSeconds)
        cooldownSeconds = value(.cooldownSeconds, defaults.cooldownSeconds)
        graceSeconds = value(.graceSeconds, defaults.graceSeconds)
        protectFrontmost = value(.protectFrontmost, defaults.protectFrontmost)
        minFootprintMB = value(.minFootprintMB, defaults.minFootprintMB)
        unlistedPolicy = value(.unlistedPolicy, defaults.unlistedPolicy)
        notify = value(.notify, defaults.notify)
        groups = value(.groups, defaults.groups)
        seeded = value(.seeded, defaults.seeded)
    }

    /// The bundle id of the group an app sits in, if any.
    public func groupIndex(forBundleID bundleID: String) -> Int? {
        let key = bundleID.lowercased()
        return groups.firstIndex { group in group.apps.contains { $0.bundleID.lowercased() == key } }
    }

    /// True for apps that should not be closed casually: anything in a "never close" group, and
    /// apps in no group that the catalog marks as system pieces. A group the user chose always wins.
    public func isProtected(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if let index = groupIndex(forBundleID: bundleID) { return groups[index].action == .never }
        return AppCatalog.classify(bundleID: bundleID, category: nil) == .never
    }

    // MARK: Seeding

    /// The four starting groups, in closing order, filled from the catalog.
    public static func seedGroups(installed: [InstalledApp]) -> [TriageGroup] {
        var buckets: [DefaultTier: [AppRule]] = [:]
        var seen = Set<String>()
        for app in installed.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let key = app.bundleID.lowercased()
            guard !seen.contains(key) else { continue }
            guard let tier = AppCatalog.classify(bundleID: app.bundleID, category: app.category) else { continue }
            seen.insert(key)
            buckets[tier, default: []].append(AppRule(bundleID: app.bundleID, name: app.name))
        }
        return [
            TriageGroup(name: "Close first", action: .politeThenForce, order: .largestFirst, apps: buckets[.closeFirst] ?? []),
            TriageGroup(name: "Close next", action: .politeThenForce, order: .largestFirst, apps: buckets[.closeNext] ?? []),
            TriageGroup(name: "Last resort", action: .polite, order: .largestFirst, apps: buckets[.lastResort] ?? []),
            TriageGroup(name: "Never close", action: .never, order: .listOrder, apps: buckets[.never] ?? []),
        ]
    }
}
