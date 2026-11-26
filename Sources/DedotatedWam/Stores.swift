import AppKit
import Foundation
import WamCore

enum AppPaths {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.dedotatedwam.app"

    /// ~/Library/Application Support/DedotatedWam
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("DedotatedWam", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}

// MARK: - Settings

/// Owns the settings, saves them, and hands the monitor thread a consistent copy.
final class SettingsStore: ObservableObject {
    @Published var settings: WamSettings {
        didSet {
            guard settings != oldValue else { return }
            lock.lock()
            shared = settings
            lock.unlock()
            scheduleSave()
        }
    }

    private let lock = NSLock()
    private var shared: WamSettings
    private var pendingSave: DispatchWorkItem?
    private let fileURL: URL?

    /// Safe to read from any thread.
    var current: WamSettings {
        lock.lock()
        defer { lock.unlock() }
        return shared
    }

    /// - Parameter persist: false keeps everything in memory (used for preview rendering).
    init(persist: Bool = true) {
        fileURL = persist ? AppPaths.supportDirectory.appendingPathComponent("settings.json") : nil
        var loaded = WamSettings()
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(WamSettings.self, from: data) {
                loaded = decoded
            } else {
                // Unreadable settings: keep the file for inspection and start fresh.
                try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("broken"))
            }
        }
        var needsSave = false
        if !loaded.seeded {
            loaded.groups = WamSettings.seedGroups(installed: InstalledApps.scan())
            loaded.seeded = true
            needsSave = true
        }
        settings = loaded
        shared = loaded
        if needsSave { save() }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Group editing

    /// Puts an app in a group (at the end), removing it from wherever it was.
    func assign(bundleID: String, name: String, toGroup groupID: UUID) {
        var groups = settings.groups
        let key = bundleID.lowercased()
        for index in groups.indices { groups[index].apps.removeAll { $0.bundleID.lowercased() == key } }
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].apps.append(AppRule(bundleID: bundleID, name: name))
        }
        settings.groups = groups
    }

    func unassign(bundleID: String) {
        let key = bundleID.lowercased()
        var groups = settings.groups
        for index in groups.indices { groups[index].apps.removeAll { $0.bundleID.lowercased() == key } }
        settings.groups = groups
    }

    func moveGroup(_ groupID: UUID, by offset: Int) {
        guard let index = settings.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let target = index + offset
        guard settings.groups.indices.contains(target) else { return }
        settings.groups.swapAt(index, target)
    }

    func addGroup() {
        // New groups go just above the first "never" group, so they are still reachable.
        let group = TriageGroup(name: "New group", action: .polite, order: .listOrder)
        let index = settings.groups.firstIndex { $0.action == .never } ?? settings.groups.count
        settings.groups.insert(group, at: index)
    }

    func deleteGroup(_ groupID: UUID) {
        settings.groups.removeAll { $0.id == groupID }
    }

    /// Throws away the current groups and rebuilds the suggested ones.
    func resetGroupsToSuggested() {
        settings.groups = WamSettings.seedGroups(installed: InstalledApps.scan())
    }
}

// MARK: - Activity log

struct LogEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// Closed automatically.
        case auto
        /// "Warn only" mode: nothing was touched.
        case wouldClose
        /// Closed by the user from the popover.
        case manual
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var appName: String
    var bundleID: String?
    var method: CloseMethod
    var succeeded: Bool
    var footprint: UInt64
    var detail: String

    var summary: String {
        switch kind {
        case .auto: return "\(method.verb) \(appName)" + (succeeded ? "" : " (failed)")
        case .wouldClose: return "Would \(method.verb.lowercased()) \(appName)"
        case .manual: return "You \(method == .polite ? "quit" : "force quit") \(appName)" + (succeeded ? "" : " (failed)")
        }
    }
}

/// What the app has closed, newest first. Kept on disk so it can be read after a rough patch.
final class ActivityLog: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    private let fileURL: URL?
    private let limit = 200

    init(persist: Bool = true) {
        fileURL = persist ? AppPaths.supportDirectory.appendingPathComponent("activity.json") : nil
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.withDates.decode([LogEntry].self, from: data) {
            entries = decoded
        }
    }

    /// Callable from any thread.
    func add(_ entry: LogEntry) {
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.limit { self.entries.removeLast(self.entries.count - self.limit) }
            self.save()
        }
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder.withDates.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let withDates: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let withDates: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Installed apps

enum InstalledApps {
    private static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Apps in the usual folders, one folder level deep.
    static func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        let manager = FileManager.default
        for root in roots {
            guard let items = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = root + "/" + item
                if item.hasSuffix(".app") {
                    add(path, to: &found)
                } else if !item.hasPrefix("."), let nested = try? manager.contentsOfDirectory(atPath: path) {
                    for inner in nested where inner.hasSuffix(".app") { add(path + "/" + inner, to: &found) }
                }
            }
        }
        // Finder lives outside the usual folders but is always running, so list it explicitly.
        add("/System/Library/CoreServices/Finder.app", to: &found)
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func add(_ path: String, to found: inout [String: InstalledApp]) {
        guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else { return }
        let key = bundleID.lowercased()
        guard found[key] == nil else { return }
        let info = bundle.infoDictionary ?? [:]
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        found[key] = InstalledApp(
            bundleID: bundleID,
            name: name,
            category: info["LSApplicationCategoryType"] as? String,
            path: path
        )
    }
}

// MARK: - Icons

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    /// Main thread only.
    static func icon(bundleID: String?, pid: pid_t? = nil) -> NSImage {
        let key = bundleID?.lowercased() ?? "pid-\(pid ?? 0)"
        if let cached = cache[key] { return cached }
        var image: NSImage?
        if let pid { image = NSRunningApplication(processIdentifier: pid)?.icon }
        if image == nil, let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let result = image ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[key] = result
        return result
    }
}
