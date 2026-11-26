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

    @Test func softOnUsedPercent() {
        #expect(TriagePlanner.instantStage(settings: settings(), memory: memory(usedPercent: 93)) == .soft)
    }

    /// A busy Mac can report "warning" for hours while working fine, so it must be asked for.
    @Test func warningPressureAloneDoesNothingUnlessChosen() {
        let warning = memory(usedPercent: 50, pressure: .warning)
        #expect(TriagePlanner.instantStage(settings: settings(), memory: warning) == .calm)
        var custom = settings()
        custom.softOnPressureWarning = true
        #expect(TriagePlanner.instantStage(settings: custom, memory: warning) == .soft)
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

@Suite struct ProcessRuleTests {
    private func rules() -> WamSettings {
        var custom = settings()
        custom.groups[0].apps.append(AppRule.process(named: "node"))
        custom.groups[1].apps.append(AppRule.process(named: "model-runner"))
        return custom
    }

    private let loose = [
        RunningProcess(pid: 50, name: "node", footprint: 200 * mb, treeFootprint: 700 * mb, ownerPid: 9, ownerName: "Terminal"),
        RunningProcess(pid: 51, name: "Node", footprint: 150 * mb, treeFootprint: 150 * mb, ownerPid: 9, ownerName: "Terminal"),
        RunningProcess(pid: 52, name: "model-runner", footprint: 5000 * mb, treeFootprint: 5000 * mb),
        RunningProcess(pid: 53, name: "unruled", footprint: 9000 * mb, treeFootprint: 9000 * mb),
    ]

    @Test func ruleHelpers() {
        let rule = AppRule.process(named: "node")
        #expect(rule.processName == "node")
        #expect(rule.name == "node")
        #expect(AppRule(bundleID: "com.apple.Safari", name: "Safari").processName == nil)
    }

    @Test func ruledProcessesJoinTheirGroupsQueue() {
        let queue = TriagePlanner.queue(settings: rules(), apps: running, processes: loose, selfBundleID: nil)
        // Group one is list order: music, chat, then the node rule (bigger tree first).
        // Group two is biggest first: the 5 GB runner outranks the 3 GB browser.
        #expect(queue.map(\.app.pid) == [2, 1, 50, 51, 52, 4, 3])
        #expect(queue.filter(\.isProcess).map(\.app.pid) == [50, 51, 52])
        #expect(queue.first { $0.app.pid == 50 }?.app.name == "node (in Terminal)")
        // Sized by everything it started.
        #expect(queue.first { $0.app.pid == 50 }?.app.footprint == 700 * mb)
        #expect(!queue.map(\.app.pid).contains(53))
    }

    @Test func protectedAndFrontmostProcessesAreSkipped() {
        var processes = loose
        processes[2].isProtected = true
        processes[0].isOwnerFrontmost = true
        let pids = TriagePlanner.queue(settings: rules(), apps: running, processes: processes, selfBundleID: nil).map(\.app.pid)
        #expect(!pids.contains(52))
        #expect(!pids.contains(50))
        #expect(pids.contains(51))
    }

    @Test func smallProcessTreesAreSkipped() {
        var custom = rules()
        custom.minFootprintMB = 500
        let pids = TriagePlanner.queue(settings: custom, apps: [], processes: loose, selfBundleID: nil).map(\.app.pid)
        #expect(pids == [50, 52])
    }

    @Test func engineEndsAProcessAndRemembersAskingIt() {
        var engine = TriageEngine()
        let start = Date(timeIntervalSince1970: 2_000_000)
        var custom = WamSettings()
        custom.mode = .armed
        custom.groups = [TriageGroup(name: "Jobs", action: .politeThenForce, order: .largestFirst, apps: [AppRule.process(named: "model-runner")])]
        let critical = memory(usedPercent: 98, pressure: .critical)
        var methods: [CloseMethod] = []
        var alive = loose
        for second in stride(from: 0.0, through: 60, by: 1) {
            if case .close(let candidate, let method) = engine.tick(now: start + second, settings: custom, memory: critical, apps: [], processes: alive, selfBundleID: nil) {
                #expect(candidate.app.pid == 52)
                #expect(candidate.isProcess)
                methods.append(method)
                // It ignores the polite request and only dies when forced.
                if method == .force { alive.removeAll { $0.pid == candidate.app.pid } }
            }
        }
        #expect(methods == [.polite, .force])
    }

    @Test func describePicksTheBiggestPlusRuledNames() {
        let entries = [
            ProcessEntry(pid: 100, ppid: 1, responsiblePid: 100, footprint: 500, name: "Browser"),
            ProcessEntry(pid: 101, ppid: 100, responsiblePid: 100, footprint: 300, name: "Browser Helper"),
            ProcessEntry(pid: 102, ppid: 101, responsiblePid: 100, footprint: 40, name: "gpu"),
            ProcessEntry(pid: 300, ppid: 1, responsiblePid: 300, footprint: 900, name: "daemon"),
            ProcessEntry(pid: 400, ppid: 1, responsiblePid: 400, footprint: 5, name: "tiny-job"),
            ProcessEntry(pid: 500, ppid: 1, responsiblePid: 500, footprint: 4, name: "noise"),
        ]
        let described = ProcessScanner.describe(
            processes: entries,
            units: [100: true],
            owners: [100: ProcessOwner(name: "Browser", isFrontmost: true)],
            ruleNames: ["tiny-job"],
            top: 3,
            pathLookup: { $0 == 300 ? "/usr/libexec/daemon" : "/Applications/X.app/Contents/MacOS/x" }
        )
        // The three biggest, plus the ruled name; "gpu" and "noise" are left out.
        #expect(described.map(\.pid) == [300, 100, 101, 400])
        let main = described.first { $0.pid == 100 }!
        #expect(main.isAppMain)
        #expect(main.treeFootprint == 840)
        let helper = described.first { $0.pid == 101 }!
        #expect(!helper.isAppMain)
        #expect(helper.ownerName == "Browser")
        #expect(helper.isOwnerFrontmost)
        #expect(helper.treeFootprint == 340)
        #expect(helper.displayName == "Browser Helper (in Browser)")
        // Lives in a system folder.
        #expect(described.first { $0.pid == 300 }!.isProtected)
        #expect(described.first { $0.pid == 300 }!.ownerPid == nil)
        #expect(!described.first { $0.pid == 400 }!.isProtected)
    }

    @Test func systemProcessesAreProtected() {
        #expect(ProcessCatalog.isProtected(name: "WindowServer", path: nil))
        #expect(ProcessCatalog.isProtected(name: "Finder", path: nil))
        #expect(ProcessCatalog.isProtected(name: "anything", path: "/System/Library/CoreServices/x"))
        #expect(ProcessCatalog.isProtected(name: "anything", path: "/usr/libexec/x"))
        #expect(!ProcessCatalog.isProtected(name: "node", path: "/opt/homebrew/bin/node"))
        #expect(!ProcessCatalog.isProtected(name: "python3", path: "/usr/bin/python3"))
        #expect(!ProcessCatalog.isProtected(name: "ollama", path: nil))
    }

    @Test func processRulesSurviveSavingAndLoading() throws {
        let original = rules()
        let decoded = try JSONDecoder().decode(WamSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded.groups[0].apps.last?.processName == "node")
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

@Suite struct BatteryTests {
    @Test func lowBatteryOnlyWarnsWhenUnplugged() {
        #expect(BatterySample(percent: 50, isCharging: false, onAC: false).severity == 0)
        #expect(BatterySample(percent: 20, isCharging: false, onAC: false).severity == 1)
        #expect(BatterySample(percent: 10, isCharging: false, onAC: false).severity == 2)
        #expect(BatterySample(percent: 5, isCharging: true, onAC: true).severity == 0)
    }

    @Test func labels() {
        #expect(BatterySample(percent: 40, isCharging: false, onAC: false, minutesRemaining: 135).remainingLabel == "2:15 until empty")
        #expect(BatterySample(percent: 40, isCharging: true, onAC: true, minutesRemaining: 40).remainingLabel == "0:40 until full")
        #expect(BatterySample(percent: 100, isCharging: false, onAC: true, minutesRemaining: 40).remainingLabel == nil)
        #expect(BatterySample(percent: 40, isCharging: false, onAC: false).remainingLabel == nil)
        #expect(BatterySample(percent: 100, isCharging: false, onAC: true).stateLabel == "Plugged in")
    }

    @Test func readingIsSaneWhenThereIsABattery() {
        guard let battery = BatterySampler.sample() else { return }
        #expect((0...100).contains(battery.percent))
        #expect(!battery.isCharging || battery.onAC)
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

    @Test func protectedMeansNeverGroupOrCatalogSystemApp() {
        let custom = settings()
        // In the "never" group.
        #expect(custom.isProtected(bundleID: "z.finder"))
        // In a closeable group: the user's choice wins, even for a system app.
        #expect(!custom.isProtected(bundleID: "a.music"))
        var moved = custom
        moved.groups[0].apps.append(AppRule(bundleID: "com.apple.finder", name: "Finder"))
        #expect(!moved.isProtected(bundleID: "com.apple.finder"))
        // In no group: the catalog decides.
        #expect(custom.isProtected(bundleID: "com.apple.finder"))
        #expect(custom.isProtected(bundleID: "com.apple.campo"))
        #expect(!custom.isProtected(bundleID: "org.example.nobody-knows"))
        #expect(!custom.isProtected(bundleID: nil))
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
