import Foundation
import Testing
@testable import WamCore

private let gb: UInt64 = 1 << 30
private let mb: UInt64 = 1 << 20

private func memory(usedPercent: Double, pressure: PressureLevel = .normal, swapGB: Double = 0) -> MemorySample {
    let total = 16 * gb
    return MemorySample(
        total: total,
        app: UInt64(Double(total) * usedPercent / 100),
        swapUsed: UInt64(swapGB * Double(gb)),
        pressure: pressure
    )
}

private func app(_ pid: pid_t, _ bundleID: String?, mb megabytes: UInt64, frontmost: Bool = false, regular: Bool = true) -> RunningApp {
    RunningApp(pid: pid, bundleID: bundleID, name: bundleID ?? "pid \(pid)", footprint: megabytes * mb, isFrontmost: frontmost, isRegular: regular)
}

private func settings(mode: AutoCloseMode = .armed) -> WamSettings {
    var settings = WamSettings()
    settings.mode = mode
    settings.groups = [
        TriageGroup(name: "First", action: .politeThenForce, order: .listOrder, apps: [
            AppRule(bundleID: "a.music", name: "Music"),
            AppRule(bundleID: "a.chat", name: "Chat"),
        ]),
        TriageGroup(name: "Next", action: .polite, order: .largestFirst, apps: [
            AppRule(bundleID: "b.browser", name: "Browser"),
            AppRule(bundleID: "b.mail", name: "Mail"),
        ]),
        TriageGroup(name: "Never", action: .never, order: .listOrder, apps: [
            AppRule(bundleID: "z.finder", name: "Finder"),
        ]),
    ]
    return settings
}

private let running = [
    app(1, "a.chat", mb: 900),
    app(2, "a.music", mb: 300),
    app(3, "b.mail", mb: 400),
    app(4, "b.browser", mb: 3000),
    app(5, "z.finder", mb: 800),
    app(6, "x.unlisted", mb: 2000),
]

@Suite struct StageTests {
    @Test func calmBelowEveryThreshold() {
        #expect(TriagePlanner.instantStage(settings: settings(), memory: memory(usedPercent: 80)) == .calm)
    }

    @Test func softOnWarningPressureOrUsedPercent() {
        #expect(TriagePlanner.instantStage(settings: settings(), memory: memory(usedPercent: 50, pressure: .warning)) == .soft)
        #expect(TriagePlanner.instantStage(settings: settings(), memory: memory(usedPercent: 93)) == .soft)
    }

    @Test func hardOnCriticalPressureOrUsedPercent() {
        #expect(TriagePlanner.instantStage(settings: settings(), memory: memory(usedPercent: 50, pressure: .critical)) == .hard)
        #expect(TriagePlanner.instantStage(settings: settings(), memory: memory(usedPercent: 98)) == .hard)
    }

    @Test func disabledTriggersAreIgnored() {
        var custom = settings()
        custom.softOnPressureWarning = false
        custom.softOnUsedPercent = false
        custom.hardOnPressureCritical = false
        custom.hardOnUsedPercent = false
        #expect(TriagePlanner.instantStage(settings: custom, memory: memory(usedPercent: 99, pressure: .critical)) == .calm)
    }

    @Test func swapTriggerIsOptIn() {
        var custom = settings()
        #expect(TriagePlanner.instantStage(settings: custom, memory: memory(usedPercent: 50, swapGB: 10)) == .calm)
        custom.softOnSwap = true
        #expect(TriagePlanner.instantStage(settings: custom, memory: memory(usedPercent: 50, swapGB: 10)) == .soft)
    }
}

@Suite struct QueueTests {
    @Test func groupsInOrderThenEachGroupsOwnOrdering() {
        let queue = TriagePlanner.queue(settings: settings(), apps: running, selfBundleID: nil)
        // "First" is list order (music before chat); "Next" is biggest first (browser before mail).
        #expect(queue.map(\.app.bundleID) == ["a.music", "a.chat", "b.browser", "b.mail"])
        #expect(queue.map(\.groupName) == ["First", "First", "Next", "Next"])
    }

    @Test func neverGroupAndUnlistedAppsAreLeftAlone() {
        let ids = TriagePlanner.queue(settings: settings(), apps: running, selfBundleID: nil).map(\.app.bundleID)
        #expect(!ids.contains("z.finder"))
        #expect(!ids.contains("x.unlisted"))
    }

    @Test func unlistedAppsComeLastWhenAllowed() {
        var custom = settings()
        custom.unlistedPolicy = .lastResort
        let queue = TriagePlanner.queue(settings: custom, apps: running, selfBundleID: nil)
        #expect(queue.last?.app.bundleID == "x.unlisted")
        #expect(queue.last?.action == .polite)
        #expect(!queue.map(\.app.bundleID).contains("z.finder"))
    }

    @Test func catalogProtectsUnlistedSystemApps() {
        var custom = settings()
        custom.unlistedPolicy = .lastResort
        let apps = running + [app(7, "com.apple.finder", mb: 900)]
        let ids = TriagePlanner.queue(settings: custom, apps: apps, selfBundleID: nil).map(\.app.bundleID)
        #expect(!ids.contains("com.apple.finder"))
        #expect(ids.contains("x.unlisted"))
    }

    @Test func frontmostAppIsProtected() {
        var apps = running
        apps[1].isFrontmost = true
        let ids = TriagePlanner.queue(settings: settings(), apps: apps, selfBundleID: nil).map(\.app.bundleID)
        #expect(!ids.contains("a.music"))

        var custom = settings()
        custom.protectFrontmost = false
        #expect(TriagePlanner.queue(settings: custom, apps: apps, selfBundleID: nil).map(\.app.bundleID).contains("a.music"))
    }

    @Test func smallAppsAndThisAppAreSkipped() {
        var custom = settings()
        custom.minFootprintMB = 500
        let ids = TriagePlanner.queue(settings: custom, apps: running, selfBundleID: "a.chat").map(\.app.bundleID)
        #expect(ids == ["b.browser"])
    }

    @Test func bundleIDsMatchWithoutRegardToCase() {
        let apps = [app(9, "A.Music", mb: 300)]
        #expect(TriagePlanner.queue(settings: settings(), apps: apps, selfBundleID: nil).count == 1)
    }
}

@Suite struct EngineTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func nothingHappensWhenOff() {
        var engine = TriageEngine()
        let off = settings(mode: .off)
        for second in stride(from: 0.0, through: 60, by: 2) {
            let decision = engine.tick(now: start + second, settings: off, memory: memory(usedPercent: 99, pressure: .critical), apps: running, selfBundleID: nil)
            #expect(decision == .none)
        }
    }

    @Test func waitsForTheConditionToHold() {
        var engine = TriageEngine()
        let tight = memory(usedPercent: 93)
        #expect(engine.tick(now: start, settings: settings(), memory: tight, apps: running, selfBundleID: nil) == .none)
        #expect(engine.tick(now: start + 8, settings: settings(), memory: tight, apps: running, selfBundleID: nil) == .none)
        let decision = engine.tick(now: start + 10, settings: settings(), memory: tight, apps: running, selfBundleID: nil)
        guard case .close(let candidate, let method) = decision else {
            Issue.record("expected a close, got \(decision)")
            return
        }
        #expect(candidate.app.bundleID == "a.music")
        #expect(method == .polite)
    }

    @Test func aBriefSpikeResetsTheWait() {
        var engine = TriageEngine()
        _ = engine.tick(now: start, settings: settings(), memory: memory(usedPercent: 93), apps: running, selfBundleID: nil)
        _ = engine.tick(now: start + 6, settings: settings(), memory: memory(usedPercent: 70), apps: running, selfBundleID: nil)
        let decision = engine.tick(now: start + 12, settings: settings(), memory: memory(usedPercent: 93), apps: running, selfBundleID: nil)
        #expect(decision == .none)
    }

    @Test func cooldownSpacesOutCloses() {
        var engine = TriageEngine()
        let tight = memory(usedPercent: 93)
        _ = engine.tick(now: start, settings: settings(), memory: tight, apps: running, selfBundleID: nil)
        #expect(engine.tick(now: start + 10, settings: settings(), memory: tight, apps: running, selfBundleID: nil) != .none)
        #expect(engine.tick(now: start + 20, settings: settings(), memory: tight, apps: running, selfBundleID: nil) == .none)
        let next = engine.tick(now: start + 26, settings: settings(), memory: tight, apps: running, selfBundleID: nil)
        guard case .close(let candidate, .polite) = next else {
            Issue.record("expected a polite close, got \(next)")
            return
        }
        // Music was already asked and is still running, so the next app gets its turn.
        #expect(candidate.app.bundleID == "a.chat")
    }

    @Test func softStageNeverForceQuits() {
        var engine = TriageEngine()
        let tight = memory(usedPercent: 93)
        var methods: [CloseMethod] = []
        for second in stride(from: 0.0, through: 600, by: 2) {
            if case .close(_, let method) = engine.tick(now: start + second, settings: settings(), memory: tight, apps: running, selfBundleID: nil) {
                methods.append(method)
            }
        }
        // Four closeable apps, each asked exactly once, none forced.
        #expect(methods == [.polite, .polite, .polite, .polite])
    }

    @Test func hardStageForcesStuckAppsAfterTheGracePeriod() {
        var engine = TriageEngine()
        let critical = memory(usedPercent: 98, pressure: .critical)
        var closes: [(String?, CloseMethod, Double)] = []
        for second in stride(from: 0.0, through: 120, by: 1) {
            if case .close(let candidate, let method) = engine.tick(now: start + second, settings: settings(), memory: critical, apps: running, selfBundleID: nil) {
                closes.append((candidate.app.bundleID, method, second))
            }
        }
        // Critical memory acts after 5 s, not the full 10.
        #expect(closes.first?.2 == 5)
        let forced = closes.filter { $0.1 == .force }
        // Only the "force if stuck" group is ever forced; the polite-only group is not.
        #expect(Set(forced.map { $0.0 }) == ["a.music", "a.chat"])
        let musicAsked = closes.first { $0.0 == "a.music" && $0.1 == .polite }!.2
        let musicForced = closes.first { $0.0 == "a.music" && $0.1 == .force }!.2
        #expect(musicForced - musicAsked >= 20)
    }

    @Test func appsThatQuitAreNotForced() {
        var engine = TriageEngine()
        let critical = memory(usedPercent: 98, pressure: .critical)
        var apps = running
        var forced = 0
        for second in stride(from: 0.0, through: 120, by: 1) {
            if case .close(let candidate, let method) = engine.tick(now: start + second, settings: settings(), memory: critical, apps: apps, selfBundleID: nil) {
                if method == .force { forced += 1 }
                apps.removeAll { $0.pid == candidate.app.pid } // It obeys at once.
            }
        }
        #expect(forced == 0)
        #expect(apps.map(\.bundleID) == ["z.finder", "x.unlisted"])
    }

    @Test func warnOnlyReportsOncePerEpisodeAndClosesNothing() {
        var engine = TriageEngine()
        let warn = settings(mode: .notifyOnly)
        var warnings = 0
        for second in stride(from: 0.0, through: 120, by: 2) {
            switch engine.tick(now: start + second, settings: warn, memory: memory(usedPercent: 93), apps: running, selfBundleID: nil) {
            case .wouldClose: warnings += 1
            case .close: Issue.record("warn only must not close anything")
            case .none: break
            }
        }
        #expect(warnings == 1)
        // Recovery, then a new episode warns again.
        _ = engine.tick(now: start + 130, settings: warn, memory: memory(usedPercent: 60), apps: running, selfBundleID: nil)
        for second in stride(from: 132.0, through: 160, by: 2) {
            if case .wouldClose = engine.tick(now: start + second, settings: warn, memory: memory(usedPercent: 93), apps: running, selfBundleID: nil) {
                warnings += 1
            }
        }
        #expect(warnings == 2)
    }
}

@Suite struct ProcessRollupTests {
    @Test func helpersAreChargedToTheirApp() {
        let processes = [
            ProcessEntry(pid: 100, ppid: 1, responsiblePid: 100, footprint: 500, name: "Browser"),
            ProcessEntry(pid: 101, ppid: 100, responsiblePid: 100, footprint: 300, name: "Browser Helper"),
            // An XPC service: child of launchd, but the browser is responsible for it.
            ProcessEntry(pid: 102, ppid: 1, responsiblePid: 100, footprint: 200, name: "WebContent"),
            // A background helper app that is itself a unit, under a regular app.
            ProcessEntry(pid: 201, ppid: 200, responsiblePid: 200, footprint: 50, name: "Chat Helper"),
            ProcessEntry(pid: 200, ppid: 1, responsiblePid: 200, footprint: 100, name: "Chat"),
            // A menu bar app on its own, and a shell tool under it.
            ProcessEntry(pid: 300, ppid: 1, responsiblePid: 300, footprint: 40, name: "MenuThing"),
            ProcessEntry(pid: 301, ppid: 300, responsiblePid: 0, footprint: 10, name: "tool"),
            // A daemon nobody owns.
            ProcessEntry(pid: 400, ppid: 1, responsiblePid: 400, footprint: 999, name: "daemon"),
        ]
        let units: [pid_t: Bool] = [100: true, 200: true, 201: false, 300: false]
        let totals = ProcessScanner.footprintByApp(processes: processes, units: units)
        #expect(totals == [100: 1000, 200: 150, 300: 50])
    }

    @Test func scanSeesThisProcess() {
        let own = ProcessScanner.scan().first { $0.pid == getpid() }
        #expect(own != nil)
        #expect((own?.footprint ?? 0) > 0)
    }
}

@Suite struct SamplerTests {
    @Test func memoryNumbersAreSane() {
        let sample = MemorySampler.sample()
        #expect(sample.total > 0)
        #expect(sample.used > 0)
        #expect(sample.used <= sample.total)
        #expect(sample.app + sample.wired + sample.compressed + sample.cached + sample.free <= sample.total + sample.total / 10)
    }

    @Test func cpuLoadIsAFraction() async throws {
        let sampler = CPUSampler()
        _ = sampler.sample()
        try await Task.sleep(for: .milliseconds(200))
        let sample = sampler.sample()
        #expect(!sample.perCore.isEmpty)
        #expect((0...1).contains(sample.total))
        #expect(sample.perCore.allSatisfy { (0...1).contains($0) })
    }
}

@Suite struct SettingsTests {
    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(WamSettings.self, from: Data(#"{"mode":"armed","softUsedPercent":85}"#.utf8))
        #expect(decoded.mode == .armed)
        #expect(decoded.softUsedPercent == 85)
        #expect(decoded.hardUsedPercent == WamSettings().hardUsedPercent)
        #expect(decoded.protectFrontmost)
    }

    @Test func roundTrips() throws {
        let original = settings()
        let decoded = try JSONDecoder().decode(WamSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func autoCloseStartsOff() {
        #expect(WamSettings().mode == .off)
    }
}

@Suite struct CatalogTests {
    @Test func essentialsAreProtected() {
        #expect(AppCatalog.classify(bundleID: "com.apple.finder", category: nil) == .never)
        #expect(AppCatalog.classify(bundleID: "com.dedotatedwam.app", category: nil) == .never)
        #expect(AppCatalog.classify(bundleID: "com.apple.ActivityMonitor", category: nil) == .never)
    }

    @Test func wellKnownAppsLandInSensibleTiers() {
        #expect(AppCatalog.classify(bundleID: "com.apple.Music", category: nil) == .closeFirst)
        #expect(AppCatalog.classify(bundleID: "com.apple.Safari", category: nil) == .closeNext)
        #expect(AppCatalog.classify(bundleID: "com.apple.dt.Xcode", category: nil) == .lastResort)
        #expect(AppCatalog.classify(bundleID: "com.apple.Terminal", category: nil) == .lastResort)
    }

    @Test func unknownAppsStayUnsortedUnlessTheirCategoryHelps() {
        #expect(AppCatalog.classify(bundleID: "org.example.nobody-knows", category: nil) == nil)
        #expect(AppCatalog.classify(bundleID: "org.example.some-game", category: "public.app-category.games") == .closeFirst)
    }

    @Test func seedingSortsInstalledAppsIntoFourGroups() {
        let groups = WamSettings.seedGroups(installed: [
            InstalledApp(bundleID: "com.apple.Music", name: "Music", category: nil, path: ""),
            InstalledApp(bundleID: "com.apple.Safari", name: "Safari", category: nil, path: ""),
            InstalledApp(bundleID: "com.apple.finder", name: "Finder", category: nil, path: ""),
            InstalledApp(bundleID: "org.example.nobody-knows", name: "Mystery", category: nil, path: ""),
        ])
        #expect(groups.map(\.name) == ["Close first", "Close next", "Last resort", "Never close"])
        #expect(groups[0].apps.map(\.name) == ["Music"])
        #expect(groups[1].apps.map(\.name) == ["Safari"])
        #expect(groups[3].apps.map(\.name) == ["Finder"])
        #expect(groups.last?.action == .never)
        #expect(!groups.flatMap(\.apps).contains { $0.name == "Mystery" })
    }
}
