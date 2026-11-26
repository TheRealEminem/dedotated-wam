import AppKit
import SwiftUI
import WamCore

/// Draws the menu bar meters, popover and settings with made-up numbers into PNG files.
/// Run with `--render-previews <folder>`. Nothing here touches real settings or closes anything.
enum PreviewRenderer {
    static func run(outputDirectory: String) {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = SettingsStore(persist: false)
        let log = ActivityLog(persist: false)
        let monitor = Monitor(store: store, log: log)
        log.add(LogEntry(kind: .auto, appName: "Music", bundleID: "com.apple.Music", method: .polite, succeeded: true, footprint: 412 << 20, detail: "93% used, pressure warning. Group: Close first."))
        log.add(LogEntry(kind: .auto, appName: "Example Browser", bundleID: nil, method: .force, succeeded: true, footprint: 3 << 30, detail: "98% used, pressure critical. Group: Close next."))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        renderMenuBar(to: directory.appendingPathComponent("menubar.png"), settings: store.settings)

        for (name, severity, dark) in [("popover-calm", 0, false), ("popover-critical", 2, true)] {
            monitor.snapshot = sample(severity: severity, settings: store.settings)
            store.settings.mode = severity == 0 ? .off : .armed
            let view = PopoverView(monitor: monitor, store: store, log: log, openSettings: {})
            render(view, dark: dark, to: directory.appendingPathComponent("\(name).png"))
        }

        monitor.snapshot = sample(severity: 0, settings: store.settings)
        for (index, name) in ["settings-general", "settings-autoclose", "settings-priorities", "settings-activity"].enumerated() {
            let view = SettingsView(monitor: monitor, store: store, log: log, tab: index)
            render(view, dark: false, to: directory.appendingPathComponent("\(name).png"))
        }
        print("Previews written to \(directory.path)")
    }

    // MARK: Fake data

    static func sample(severity: Int, settings: WamSettings) -> Snapshot {
        let gb: UInt64 = 1 << 30
        var snapshot = Snapshot()
        let usedShare: [Double] = [0.62, 0.93, 0.98]
        let total = 16 * gb
        let used = UInt64(Double(total) * usedShare[severity])
        snapshot.memory = MemorySample(
            total: total,
            app: used * 55 / 100,
            wired: used * 20 / 100,
            compressed: used * 25 / 100,
            cached: (total - used) * 70 / 100,
            free: (total - used) * 30 / 100,
            swapUsed: UInt64(severity) * 3 * gb + gb / 2,
            swapTotal: 8 * gb,
            pressure: [.normal, .warning, .critical][severity]
        )
        let cores: [Double] = [0.82, 0.64, 0.71, 0.33, 0.18, 0.09, 0.27, 0.12, 0.05, 0.02]
        snapshot.cpu = CPUSample(total: 0.34, user: 0.23, system: 0.11, perCore: cores)
        snapshot.cpuHistory = (0..<Snapshot.historyLength).map { 0.3 + 0.25 * sin(Double($0) / 4) + 0.1 * sin(Double($0) * 1.7) }
        snapshot.memoryHistory = (0..<Snapshot.historyLength).map {
            usedShare[severity] - 0.12 + 0.12 * Double($0) / Double(Snapshot.historyLength) + 0.01 * sin(Double($0))
        }
        snapshot.instantStage = [.calm, .soft, .hard][severity]
        snapshot.stage = snapshot.instantStage

        // Borrow names and icons from whatever the seeded groups contain.
        let rules = settings.groups.flatMap { group in group.apps.prefix(2) }
        let sizes: [UInt64] = [3200, 2100, 1400, 900, 640, 380, 210, 120]
        snapshot.apps = zip(rules, sizes).enumerated().map { index, pair in
            RunningApp(pid: pid_t(1000 + index), bundleID: pair.0.bundleID, name: pair.0.name, footprint: pair.1 << 20, isFrontmost: index == 1, isRegular: true)
        }
        .sorted { $0.footprint > $1.footprint }
        snapshot.queue = TriagePlanner.queue(settings: settings, apps: snapshot.apps, selfBundleID: AppPaths.bundleID)
        return snapshot
    }

    // MARK: Rendering

    private static func render<V: View>(_ view: V, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Every style at every severity, on a light and a dark strip, enlarged so details are visible.
    private static func renderMenuBar(to url: URL, settings: WamSettings) {
        let scale: CGFloat = 4
        let rowHeight: CGFloat = 26
        var rows: [(NSImage, Bool)] = []
        for dark in [false, true] {
            for style in MenuBarStyle.allCases {
                for graph in CPUGraphStyle.allCases where !(style == .compact && graph == .cores) {
                    for severity in 0...2 {
                        var variant = settings
                        variant.menuBarStyle = style
                        variant.cpuGraphStyle = graph
                        let image = MenuBarRenderer.image(snapshot: sample(severity: severity, settings: settings), settings: variant, dark: dark)
                        rows.append((image.isTemplate ? tinted(image, dark ? .white : .black) : image, dark))
                    }
                }
            }
        }
        let columns = 3
        let cellWidth: CGFloat = 150
        let rowCount = Int(ceil(Double(rows.count) / Double(columns)))
        let pixelsWide = Int(cellWidth * CGFloat(columns) * scale)
        let pixelsHigh = Int(rowHeight * CGFloat(rowCount) * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        bitmap.size = NSSize(width: cellWidth * CGFloat(columns), height: rowHeight * CGFloat(rowCount))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for (index, row) in rows.enumerated() {
            let column = index % columns
            let line = index / columns
            let cell = NSRect(
                x: CGFloat(column) * cellWidth,
                y: bitmap.size.height - CGFloat(line + 1) * rowHeight,
                width: cellWidth,
                height: rowHeight
            )
            (row.1 ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
            cell.fill()
            let size = row.0.size
            row.0.draw(in: NSRect(x: cell.minX + 10, y: cell.midY - size.height / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}
