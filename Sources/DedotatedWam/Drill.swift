import AppKit
import Foundation
import WamCore

/// Developer aid: a live check that auto-close really closes things.
///
/// It runs the real monitor and the real closing code, told that memory is critical, with settings
/// of its own that list only the targets named on the command line. Nothing else can be closed, and
/// the saved settings and activity log are neither read nor written. `Scripts/drill.sh` builds
/// throwaway targets and runs this.
enum Drill {
    private static let timeout: TimeInterval = 60

    static func run(targets: [String]) -> Never {
        guard !targets.isEmpty else {
            stop("usage: --drill <bundle id | process:name> ...")
        }

        var rules: [AppRule] = []
        for target in targets {
            let rule = AppRule(bundleID: target, name: target)
            if let name = rule.processName {
                rules.append(.process(named: name))
            } else if AppCatalog.classify(bundleID: target, category: nil) == .never {
                stop("\(target) is a protected system app. The drill will not close it.")
            } else {
                rules.append(rule)
            }
        }
        let keys = Set(rules.map { $0.bundleID.lowercased() })

        var settings = WamSettings()
        settings.seeded = true
        settings.mode = .armed
        settings.groups = [TriageGroup(name: "Drill", action: .politeThenForce, order: .listOrder, apps: rules)]
        settings.unlistedPolicy = .ignore
        // Any reading counts as critical, so both stages are reached without real memory trouble.
        settings.softOnUsedPercent = true
        settings.softUsedPercent = 0
        settings.hardOnUsedPercent = true
        settings.hardUsedPercent = 0
        settings.sustainSeconds = 2
        settings.cooldownSeconds = 9
        settings.graceSeconds = 6
        settings.refreshSeconds = 1
        settings.notify = false

        let store = SettingsStore(persist: false)
        store.settings = settings
        let log = ActivityLog(persist: false)
        let monitor = Monitor(store: store, log: log)

        var seen = Set<String>()
        var present = Set<String>()
        var ticks = 0
        monitor.onTick = { snapshot in
            present = []
            for app in snapshot.apps {
                if let id = app.bundleID?.lowercased(), keys.contains(id) { present.insert(id) }
            }
            for process in snapshot.processes {
                let key = AppRule.processPrefix + process.name.lowercased()
                if keys.contains(key) { present.insert(key) }
            }
            seen.formUnion(present)
            ticks += 1
        }

        print("Drill: acting as if memory were critical. Only these can be closed:")
        for rule in rules { print("  \(rule.processName.map { "process \($0)" } ?? rule.bundleID)") }

        let started = Date()
        var printed = 0
        monitor.start()
        while Date().timeIntervalSince(started) < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let entries = log.entries
            for entry in entries.prefix(entries.count - printed).reversed() {
                let second = Int(entry.date.timeIntervalSince(started).rounded())
                print("  +\(second)s  \(entry.summary)  (\(ByteFormat.string(entry.footprint)))")
            }
            printed = entries.count

            guard ticks >= 3 else { continue }
            let missing = keys.subtracting(seen)
            if !missing.isEmpty {
                stop("Not running, so there is nothing to test: \(missing.sorted().joined(separator: ", "))")
            }
            if present.isEmpty { break }
        }

        if present.isEmpty {
            print("Drill passed: every target was closed in \(Int(Date().timeIntervalSince(started))) seconds.")
            exit(0)
        }
        stop("Drill FAILED: still running after \(Int(timeout)) seconds: \(present.sorted().joined(separator: ", "))")
    }

    private static func stop(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
