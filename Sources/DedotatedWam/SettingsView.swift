import AppKit
import ServiceManagement
import SwiftUI
import WamCore

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var store: SettingsStore
    @ObservedObject var log: ActivityLog
    @Local var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)
            AutoCloseTab(monitor: monitor, store: store)
                .tabItem { Label("Auto-close", systemImage: "bolt.shield") }
                .tag(1)
            PrioritiesTab(monitor: monitor, store: store)
                .tabItem { Label("Priorities", systemImage: "list.number") }
                .tag(2)
            ActivityTab(log: log)
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(3)
        }
        .frame(width: 660, height: 560)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @Local private var launchAtLogin = LoginItem.isEnabled
    @Local private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        loginError = LoginItem.set(enabled)
                        launchAtLogin = LoginItem.isEnabled
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Menu bar") {
                Picker("Show", selection: $store.settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("CPU graph", selection: $store.settings.cpuGraphStyle) {
                    ForEach(CPUGraphStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(store.settings.menuBarStyle == .compact)
                Toggle("Turn the memory meter orange or red when memory is tight", isOn: $store.settings.colorByPressure)
                Toggle("Show the battery", isOn: $store.settings.showBattery)
                    .disabled(BatterySampler.sample() == nil)
                Picker("Update every", selection: $store.settings.refreshSeconds) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil if it worked.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not change the login item: \(error.localizedDescription) Move the app to the Applications folder and try again."
        }
    }
}

// MARK: - Auto-close

private struct AutoCloseTab: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var store: SettingsStore

    var body: some View {
        let memory = monitor.snapshot.memory
        Form {
            Section {
                Picker("Mode", selection: $store.settings.mode) {
                    ForEach(AutoCloseMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(modeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Right now") {
                    Text("\(memory.usedPercent)% used · swap \(ByteFormat.string(memory.swapUsed)) · pressure \(memory.pressure.label.lowercased())")
                        .monospacedDigit()
                }
            }
            .onChange(of: store.settings.mode) { _, mode in
                if mode != .off { Notifier.requestPermission() }
            }

            Section("Stage 1: ask apps to quit when") {
                Toggle(isOn: $store.settings.softOnPressureWarning) {
                    Text("macOS reports memory pressure as Warning")
                    Text("A Mac with a lot open can stay at Warning for hours while working fine.")
                }
                ThresholdRow(title: "Memory used reaches", isOn: $store.settings.softOnUsedPercent, value: $store.settings.softUsedPercent, range: 50...99, unit: "%")
                Toggle(isOn: $store.settings.softOnSwap) {
                    Stepper(value: $store.settings.softSwapGB, in: 1...64, step: 1) {
                        Text("Swap used reaches \(Int(store.settings.softSwapGB)) GB")
                    }
                }
            }
            Section("Stage 2: allow force quit when") {
                Toggle("macOS reports memory pressure as Critical", isOn: $store.settings.hardOnPressureCritical)
                ThresholdRow(title: "Memory used reaches", isOn: $store.settings.hardOnUsedPercent, value: $store.settings.hardUsedPercent, range: 60...100, unit: "%")
            }
            Section("Timing") {
                SecondsRow(title: "Condition must hold for", value: $store.settings.sustainSeconds, range: 2...120, step: 2)
                SecondsRow(title: "Wait between closing apps", value: $store.settings.cooldownSeconds, range: 3...120, step: 3)
                SecondsRow(title: "Time an app gets to quit nicely before force quit", value: $store.settings.graceSeconds, range: 5...180, step: 5)
            }
            Section("Safety") {
                Toggle("Never close the app I am using", isOn: $store.settings.protectFrontmost)
                Stepper(value: $store.settings.minFootprintMB, in: 0...4000, step: 50) {
                    Text("Skip apps using less than \(store.settings.minFootprintMB) MB")
                }
                Picker("Apps in no group", selection: $store.settings.unlistedPolicy) {
                    ForEach(UnlistedPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Notify me when something is closed", isOn: $store.settings.notify)
            }
        }
        .formStyle(.grouped)
    }

    private var modeHelp: String {
        switch store.settings.mode {
        case .off: return "Only the meters run. Nothing is closed for you."
        case .notifyOnly: return "When memory runs short you get a notification naming what would be closed. Nothing is touched."
        case .armed: return "When memory runs short, apps are closed in the order set under Priorities until it recovers."
        }
    }
}

private struct ThresholdRow: View {
    var title: String
    @Binding var isOn: Bool
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Stepper(value: $value, in: range) {
                Text("\(title) \(value)\(unit)")
            }
        }
    }
}

private struct SecondsRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title) { Text("\(Int(value)) s").monospacedDigit() }
        }
    }
}

// MARK: - Priorities

private struct PrioritiesTab: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var store: SettingsStore
    @Local private var installed: [InstalledApp] = []
    @Local private var search = ""
    @Local private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Groups are closed from top to bottom. Drag apps to reorder them inside a group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Filter apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List {
                ForEach($store.settings.groups) { $group in
                    Section {
                        let visible = group.apps.filter(matches)
                        ForEach(visible) { rule in
                            RuleRow(rule: rule, runningText: runningText(for: rule), currentGroup: group.id, store: store)
                        }
                        .onMove { source, destination in
                            guard search.isEmpty else { return }
                            group.apps.move(fromOffsets: source, toOffset: destination)
                        }
                        if visible.isEmpty {
                            Text(group.apps.isEmpty ? "No apps in this group yet." : "No matches.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } header: {
                        GroupHeader(group: $group, position: position(of: group.id), count: store.settings.groups.count, store: store)
                    }
                }
                Section {
                    ForEach(unsorted, id: \.bundleID) { app in
                        RuleRow(rule: AppRule(bundleID: app.bundleID, name: app.name), runningText: runningText(for: AppRule(bundleID: app.bundleID, name: app.name)), currentGroup: nil, store: store)
                    }
                    if unsorted.isEmpty {
                        Text("Every app found is in a group.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Not in any group (\(store.settings.unlistedPolicy == .ignore ? "left alone" : "quit nicely last"))")
                }
                Section {
                    ForEach(looseProcesses, id: \.name) { process in
                        RuleRow(
                            rule: AppRule.process(named: process.name),
                            runningText: "\(process.count > 1 ? "\(process.count) running" : "running") · \(ByteFormat.string(process.total))"
                                + (process.owner.map { " · in \($0)" } ?? ""),
                            currentGroup: nil,
                            store: store
                        )
                    }
                    if looseProcesses.isEmpty {
                        Text("No sizeable background processes right now.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Background processes running now (add one to a group to let it be ended on its own)")
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button("Add group") { store.addGroup() }
                Spacer()
                Button("Reset to suggested…") { confirmReset = true }
            }
            .padding(12)
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = InstalledApps.scan()
                DispatchQueue.main.async { installed = apps }
            }
        }
        .confirmationDialog("Replace all groups with the suggested ones?", isPresented: $confirmReset) {
            Button("Reset groups", role: .destructive) { store.resetGroupsToSuggested() }
        } message: {
            Text("Your current groups and their order are discarded.")
        }
    }

    private func runningText(for rule: AppRule) -> String? {
        if let processName = rule.processName {
            let matches = monitor.snapshot.processes.filter { $0.name.caseInsensitiveCompare(processName) == .orderedSame }
            guard !matches.isEmpty else { return nil }
            let total = matches.reduce(UInt64(0)) { $0 + $1.footprint }
            return "\(matches.count > 1 ? "\(matches.count) running" : "running") · \(ByteFormat.string(total))"
        }
        return runningByBundleID[rule.bundleID.lowercased()].map { "running · \(ByteFormat.string($0.footprint))" }
    }

    /// Processes that are not an app's main process, are not part of macOS and are in no group yet,
    /// added up by name.
    private var looseProcesses: [(name: String, count: Int, total: UInt64, owner: String?)] {
        var totals: [String: (name: String, count: Int, total: UInt64, owner: String?)] = [:]
        for process in monitor.snapshot.processes where !process.isAppMain && !process.isProtected {
            guard store.settings.groupIndex(forBundleID: AppRule.processPrefix + process.name) == nil else { continue }
            let key = process.name.lowercased()
            var entry = totals[key] ?? (process.name, 0, 0, process.ownerName)
            entry.count += 1
            entry.total += process.footprint
            if entry.owner != process.ownerName { entry.owner = nil }
            totals[key] = entry
        }
        return totals.values
            .filter { $0.total >= 50 << 20 && matches(AppRule.process(named: $0.name)) }
            .sorted { $0.total > $1.total }
            .prefix(12)
            .map { $0 }
    }

    private var runningByBundleID: [String: RunningApp] {
        var result: [String: RunningApp] = [:]
        for app in monitor.snapshot.apps {
            guard let key = app.bundleID?.lowercased() else { continue }
            if let existing = result[key], existing.footprint >= app.footprint { continue }
            result[key] = app
        }
        return result
    }

    /// Installed apps and running Dock apps that no group lists.
    private var unsorted: [InstalledApp] {
        var listed = Set<String>()
        for group in store.settings.groups {
            for rule in group.apps { listed.insert(rule.bundleID.lowercased()) }
        }
        var seen = listed
        var result: [InstalledApp] = []
        for app in monitor.snapshot.apps where app.isRegular {
            guard let bundleID = app.bundleID, !seen.contains(bundleID.lowercased()) else { continue }
            seen.insert(bundleID.lowercased())
            result.append(InstalledApp(bundleID: bundleID, name: app.name, category: nil, path: ""))
        }
        for app in installed where !seen.contains(app.bundleID.lowercased()) {
            seen.insert(app.bundleID.lowercased())
            result.append(app)
        }
        return result
            .filter { matches(AppRule(bundleID: $0.bundleID, name: $0.name)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func matches(_ rule: AppRule) -> Bool {
        search.isEmpty
            || rule.name.localizedCaseInsensitiveContains(search)
            || rule.bundleID.localizedCaseInsensitiveContains(search)
    }

    private func position(of groupID: UUID) -> Int {
        store.settings.groups.firstIndex { $0.id == groupID } ?? 0
    }
}

private struct GroupHeader: View {
    @Binding var group: TriageGroup
    var position: Int
    var count: Int
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(spacing: 8) {
            Text("\(position + 1)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Palette.action(group.action), in: Circle())
            TextField("Group name", text: $group.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: 150)
            Spacer()
            Picker("How to close", selection: $group.action) {
                ForEach(CloseAction.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Order", selection: $group.order) {
                ForEach(GroupOrder.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(group.action == .never)
            Button { store.moveGroup(group.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(position == 0)
                .help("Close this group earlier")
            Button { store.moveGroup(group.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(position >= count - 1)
                .help("Close this group later")
            Button { store.deleteGroup(group.id) } label: { Image(systemName: "trash") }
                .disabled(!group.apps.isEmpty)
                .help(group.apps.isEmpty ? "Delete this group" : "Move its apps elsewhere before deleting")
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }
}

private struct RuleRow: View {
    var rule: AppRule
    /// "running · 1.2 GB", or nil when it is not running.
    var runningText: String?
    var currentGroup: UUID?
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(spacing: 8) {
            if rule.processName == nil {
                Image(nsImage: IconCache.icon(bundleID: rule.bundleID))
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(rule.name).font(.system(size: 12))
                Text(rule.processName == nil ? rule.bundleID : "background process, matched by name")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let runningText {
                Text(runningText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(store.settings.groups) { group in
                    Button(group.name) { store.assign(bundleID: rule.bundleID, name: rule.name, toGroup: group.id) }
                        .disabled(group.id == currentGroup)
                }
                if currentGroup != nil {
                    Divider()
                    Button("Remove from groups") { store.unassign(bundleID: rule.bundleID) }
                }
            } label: {
                Text(currentGroup == nil ? "Add to…" : "Move to…")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Activity

private struct ActivityTab: View {
    @ObservedObject var log: ActivityLog

    var body: some View {
        VStack(spacing: 0) {
            if log.entries.isEmpty {
                Spacer()
                Text("Nothing has been closed yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(log.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(for: entry))
                            .foregroundStyle(entry.kind == .wouldClose ? Color.secondary : (entry.method == .force ? Color.red : Color.orange))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.summary).font(.system(size: 12, weight: .medium))
                            Text("\(ByteFormat.string(entry.footprint)) · \(entry.detail)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            .padding(12)
        }
    }

    private func icon(for entry: LogEntry) -> String {
        switch entry.kind {
        case .wouldClose: return "bell"
        case .manual: return "hand.tap"
        case .auto: return entry.method == .force ? "bolt.fill" : "xmark.circle.fill"
        }
    }
}
