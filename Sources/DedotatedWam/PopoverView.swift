import AppKit
import SwiftUI
import WamCore

// MARK: - Palette

enum Palette {
    static let app = Color(nsColor: .systemBlue)
    static let wired = Color(nsColor: .systemIndigo)
    static let compressed = Color(nsColor: .systemPink)
    static let cached = Color.primary.opacity(0.28)
    static let free = Color.primary.opacity(0.1)

    static func severity(_ level: Int) -> Color {
        switch level {
        case 2: return Color(nsColor: .systemRed)
        case 1: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemGreen)
        }
    }

    static func action(_ action: CloseAction) -> Color {
        switch action {
        case .force: return Color(nsColor: .systemRed)
        case .politeThenForce: return Color(nsColor: .systemOrange)
        case .polite: return Color(nsColor: .systemBlue)
        case .never: return Color.secondary
        }
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var store: SettingsStore
    @ObservedObject var log: ActivityLog
    var openSettings: () -> Void
    /// Preview rendering only: shows this app's row already asking for confirmation.
    var confirmingPid: pid_t?
    /// Preview rendering only: opens the list on Processes.
    var startOnProcesses = false

    private var snapshot: Snapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            MemoryCard(snapshot: snapshot)
            CPUCard(snapshot: snapshot)
            if let battery = snapshot.battery {
                BatteryCard(battery: battery)
            }
            AppsCard(snapshot: snapshot, settings: store.settings, log: log, confirmingPid: confirmingPid, showProcesses: startOnProcesses)
            AutoCloseCard(snapshot: snapshot, store: store, lastEntry: log.entries.first)
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Dedotated Wam")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(Palette.severity(snapshot.severity))
                    .frame(width: 7, height: 7)
                Text("Pressure: \(snapshot.memory.pressure.label)")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.severity(snapshot.severity).opacity(0.14), in: Capsule())
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

// MARK: - Cards

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CardTitle: View {
    var title: String
    var value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
        }
    }
}

private struct MemoryCard: View {
    var snapshot: Snapshot

    private var segments: [(name: String, bytes: UInt64, color: Color)] {
        let memory = snapshot.memory
        return [
            ("App", memory.app, Palette.app),
            ("Wired", memory.wired, Palette.wired),
            ("Compressed", memory.compressed, Palette.compressed),
            ("Cached", memory.cached, Palette.cached),
        ]
    }

    var body: some View {
        let memory = snapshot.memory
        Card {
            CardTitle(
                title: "Memory",
                value: "\(memory.usedPercent)%",
                detail: "\(ByteFormat.string(memory.used)) of \(ByteFormat.string(memory.total))"
            )
            GeometryReader { geometry in
                HStack(spacing: 1.5) {
                    ForEach(segments, id: \.name) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, geometry.size.width * CGFloat(Double(segment.bytes) / Double(max(1, memory.total))) - 1.5))
                    }
                    Rectangle().fill(Palette.free)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            .accessibilityLabel("Memory breakdown")

            // Two rows of two: four labels in a single row do not fit the popover.
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach([0, 2], id: \.self) { start in
                    GridRow {
                        ForEach(segments[start..<start + 2], id: \.name) { segment in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 7, height: 7)
                                Text(segment.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(ByteFormat.string(segment.bytes))
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                            }
                            .lineLimit(1)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Sparkline(values: snapshot.memoryHistory, color: Palette.severity(snapshot.severity))
                    .frame(height: 26)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Swap")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(memory.swapUsed))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
            }
        }
    }
}

private struct CPUCard: View {
    var snapshot: Snapshot

    var body: some View {
        let cpu = snapshot.cpu
        Card {
            CardTitle(
                title: "CPU",
                value: "\(Int((cpu.total * 100).rounded()))%",
                detail: "user \(Int((cpu.user * 100).rounded()))% · system \(Int((cpu.system * 100).rounded()))%"
            )
            HStack(alignment: .bottom, spacing: 10) {
                Sparkline(values: snapshot.cpuHistory, color: Palette.app)
                    .frame(height: 30)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { _, load in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Palette.app)
                                .frame(height: max(2, 30 * CGFloat(min(1, load))))
                        }
                        .frame(width: 5, height: 30)
                    }
                }
                .accessibilityLabel("Load per core")
            }
        }
    }
}

private struct BatteryCard: View {
    var battery: BatterySample

    var body: some View {
        let color = battery.severity == 0 ? Color(nsColor: .systemGreen) : Palette.severity(battery.severity)
        Card {
            CardTitle(
                title: "Battery",
                value: "\(battery.percent)%",
                detail: [battery.stateLabel, battery.remainingLabel].compactMap { $0 }.joined(separator: " · ")
            )
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.free)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: max(3, geometry.size.width * CGFloat(battery.fraction)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
    }
}

private struct AppsCard: View {
    var snapshot: Snapshot
    var settings: WamSettings
    var log: ActivityLog
    var confirmingPid: pid_t?
    /// False lists apps with their helpers rolled in; true lists every process on its own.
    @Local var showProcesses = false

    var body: some View {
        Card {
            HStack {
                Text("Biggest")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Picker("Show", selection: $showProcesses) {
                    Text("Apps").tag(false)
                    Text("Processes").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            if snapshot.apps.isEmpty {
                Text("Reading processes…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 1) {
                if showProcesses {
                    processRows
                } else {
                    appRows
                }
            }
            Text(showProcesses
                ? "Each process on its own. Ending one inside an app can break that app."
                : "Each app includes its helper processes.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var appRows: some View {
        let apps = Array(snapshot.apps.prefix(7))
        let largest = max(1, apps.first?.footprint ?? 1)
        ForEach(apps) { app in
            let group = group(forBundleID: app.bundleID)
            ClosableRow(
                pid: app.pid,
                name: app.name,
                bundleID: app.bundleID,
                icon: IconCache.icon(bundleID: app.bundleID, pid: app.pid),
                caption: nil,
                tag: group.map { ($0.name, Palette.action($0.action)) },
                footprint: app.footprint,
                isProtected: settings.isProtected(bundleID: app.bundleID),
                share: Double(app.footprint) / Double(largest),
                log: log,
                pending: app.pid == confirmingPid ? .polite : nil
            )
        }
    }

    @ViewBuilder private var processRows: some View {
        let processes = Array(snapshot.processes.prefix(8))
        let largest = max(1, processes.first?.footprint ?? 1)
        ForEach(processes) { process in
            let group = group(forBundleID: AppRule.processPrefix + process.name)
            ClosableRow(
                pid: process.pid,
                name: process.name,
                bundleID: nil,
                // An app's own main process wears the app's icon; anything else gets a gear.
                icon: process.isAppMain ? IconCache.icon(bundleID: nil, pid: process.pid) : nil,
                caption: process.isAppMain ? nil : process.ownerName.map { "in \($0)" },
                tag: group.map { ($0.name, Palette.action($0.action)) },
                footprint: process.footprint,
                isProtected: process.isProtected,
                share: Double(process.footprint) / Double(largest),
                log: log,
                pending: process.pid == confirmingPid ? .polite : nil
            )
        }
    }

    private func group(forBundleID bundleID: String?) -> TriageGroup? {
        guard let bundleID, let index = settings.groupIndex(forBundleID: bundleID) else { return nil }
        return settings.groups[index]
    }
}

/// One line in the "Biggest" list: an app or a single process, with quit buttons on hover.
private struct ClosableRow: View {
    var pid: pid_t
    var name: String
    var bundleID: String?
    /// Nil draws a gear, for processes that are not an app.
    var icon: NSImage?
    /// Small grey text after the name, such as the app a process lives in.
    var caption: String?
    var tag: (text: String, color: Color)?
    var footprint: UInt64
    /// Protected rows can still be quit from here, but only after a second, explicit click.
    var isProtected: Bool
    var share: Double
    var log: ActivityLog
    /// The quit the user has asked for on a protected row and not yet confirmed.
    @Local var pending: CloseMethod?
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            if let pending {
                confirmation(for: pending)
            } else {
                details
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(pending == nil ? Color.primary.opacity(hovering ? 0.1 : 0.05) : Color(nsColor: .systemOrange).opacity(0.16))
                    .frame(width: pending == nil ? geometry.size.width * CGFloat(min(1, max(0.02, share))) : geometry.size.width)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // Moving away is a "no".
            if !inside { pending = nil }
        }
    }

    @ViewBuilder private var details: some View {
        Text(name)
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.middle)
        if isProtected {
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .help("Protected. Quitting it from here asks first.")
        }
        if let caption {
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        if let tag {
            Text(tag.text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tag.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(tag.color.opacity(0.13), in: Capsule())
                .lineLimit(1)
                .fixedSize()
        }
        Spacer(minLength: 4)
        if hovering {
            Button {
                request(.polite)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help(isProtected ? "Quit \(name). It is protected, so you will be asked to confirm." : "Quit \(name)")
            Button {
                request(.force)
            } label: {
                Image(systemName: "bolt.circle")
            }
            .help(isProtected
                ? "Force quit \(name). It is protected, so you will be asked to confirm."
                : "Force quit \(name). Unsaved work in it is lost.")
        }
        Text(ByteFormat.string(footprint))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 58, alignment: .trailing)
    }

    @ViewBuilder private func confirmation(for method: CloseMethod) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Color(nsColor: .systemOrange))
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name) is protected")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(method.verb) it anyway?")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Spacer(minLength: 4)
        Button("Cancel") { pending = nil }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        Button(method.verb) {
            pending = nil
            close(method, confirmed: true)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(nsColor: .systemRed))
        .controlSize(.mini)
    }

    private func request(_ method: CloseMethod) {
        if isProtected {
            pending = method
        } else {
            close(method, confirmed: false)
        }
    }

    private func close(_ method: CloseMethod, confirmed: Bool) {
        let succeeded = Closer.close(pid: pid, method: method)
        log.add(LogEntry(
            kind: .manual,
            appName: name,
            bundleID: bundleID,
            method: method,
            succeeded: succeeded,
            footprint: footprint,
            detail: confirmed ? "From the menu bar popover, after confirming (protected)." : "From the menu bar popover."
        ))
    }
}

private struct AutoCloseCard: View {
    var snapshot: Snapshot
    @ObservedObject var store: SettingsStore
    var lastEntry: LogEntry?

    var body: some View {
        Card {
            HStack {
                Text("Auto-close")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Picker("Auto-close mode", selection: $store.settings.mode) {
                    ForEach(AutoCloseMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lastEntry {
                Text("Last: \(lastEntry.summary), \(lastEntry.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .onChange(of: store.settings.mode) { _, mode in
            if mode != .off { Notifier.requestPermission() }
        }
    }

    private var status: String {
        let names = snapshot.queue.prefix(3).map(\.app.name)
        let upNext = names.isEmpty ? "Nothing in your groups is running right now." : "First to go: \(names.joined(separator: ", "))."
        switch (store.settings.mode, snapshot.stage) {
        case (.off, _):
            return "Off. Nothing will be closed for you. \(upNext)"
        case (.notifyOnly, .calm):
            return "Watching. You will be warned, nothing will be closed. \(upNext)"
        case (.notifyOnly, _):
            return "Memory is tight. Warn only, so nothing is being closed. \(upNext)"
        case (.armed, .calm):
            return "Armed. If memory runs short, apps close in group order. \(upNext)"
        case (.armed, .soft):
            return "Memory is tight: asking apps to quit. \(upNext)"
        case (.armed, .hard):
            return "Memory is critical: force quitting where allowed. \(upNext)"
        }
    }
}

// MARK: - Sparkline

/// A small filled line chart of values from 0 to 1, newest on the right.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var capacity = Snapshot.historyLength

    var body: some View {
        GeometryReader { geometry in
            let points = self.points(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard capacity > 1 else { return [] }
        let offset = capacity - values.count
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index + offset) / CGFloat(capacity - 1),
                y: 1 + (size.height - 2) * CGFloat(1 - min(1, max(0, value)))
            )
        }
    }
}
