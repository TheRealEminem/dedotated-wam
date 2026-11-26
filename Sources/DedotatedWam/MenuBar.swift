import AppKit
import SwiftUI
import WamCore

// MARK: - Drawing

/// Draws the little meters that live in the menu bar.
enum MenuBarRenderer {
    static let height: CGFloat = 18

    /// - Parameter dark: whether the menu bar is dark, which only matters when a warning colour
    ///   stops the image being a template.
    static func image(snapshot: Snapshot, settings: WamSettings, dark: Bool) -> NSImage {
        let severity = settings.colorByPressure ? snapshot.severity : 0
        let base: NSColor = severity == 0 ? .black : (dark ? .white : .black)
        let accent: NSColor = severity == 2 ? .systemRed : (severity == 1 ? .systemOrange : base)

        let cpuValues: [Double]
        switch settings.cpuGraphStyle {
        case .history:
            let recent = Array(snapshot.cpuHistory.suffix(10))
            cpuValues = Array(repeating: 0, count: max(0, 10 - recent.count)) + recent
        case .cores:
            cpuValues = snapshot.cpu.perCore.isEmpty ? [0] : snapshot.cpu.perCore
        }

        let image: NSImage
        switch settings.menuBarStyle {
        case .full:
            image = drawWide(snapshot: snapshot, cpuValues: cpuValues, numbers: true, base: base, accent: accent)
        case .graphs:
            image = drawWide(snapshot: snapshot, cpuValues: cpuValues, numbers: false, base: base, accent: accent)
        case .compact:
            image = drawCompact(snapshot: snapshot, base: base, accent: accent)
        }
        // A template image lets the system pick black or white for the menu bar by itself.
        image.isTemplate = severity == 0
        return image
    }

    // MARK: Wide layouts

    private static func drawWide(snapshot: Snapshot, cpuValues: [Double], numbers: Bool, base: NSColor, accent: NSColor) -> NSImage {
        let barWidth: CGFloat = 2, barGap: CGFloat = 1
        let graphWidth = CGFloat(cpuValues.count) * (barWidth + barGap) - barGap
        let textWidth: CGFloat = numbers ? 25 : 0
        let textGap: CGFloat = numbers ? 3 : 0
        let capsuleWidth: CGFloat = 30
        let blockGap: CGFloat = numbers ? 7 : 6
        let width = graphWidth + textGap + textWidth + blockGap + capsuleWidth + textGap + textWidth

        return NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0

            // CPU: a row of thin bars over faint tracks.
            let graphBottom: CGFloat = 2, graphHeight: CGFloat = 14
            for value in cpuValues {
                let track = NSRect(x: x, y: graphBottom, width: barWidth, height: graphHeight)
                base.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                let filled = max(1.5, graphHeight * CGFloat(min(1, max(0, value))))
                base.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: graphBottom, width: barWidth, height: filled), xRadius: 1, yRadius: 1).fill()
                x += barWidth + barGap
            }
            x -= barGap
            if numbers {
                x += textGap
                drawLabel("CPU", value: percent(snapshot.cpu.total), x: x, width: textWidth, color: base, valueColor: base)
                x += textWidth
            }
            x += blockGap

            // RAM: a capsule that fills up, shaded by what kind of memory it is.
            drawCapsule(memory: snapshot.memory, rect: NSRect(x: x, y: 3.5, width: capsuleWidth, height: 11), base: base, accent: accent)
            x += capsuleWidth
            if numbers {
                x += textGap
                drawLabel("RAM", value: percent(snapshot.memory.usedFraction), x: x, width: textWidth, color: base, valueColor: accent)
            }
            return true
        }
    }

    private static func drawCapsule(memory: MemorySample, rect: NSRect, base: NSColor, accent: NSColor) {
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        base.withAlphaComponent(0.55).setStroke()
        outline.stroke()

        let inner = rect.insetBy(dx: 2, dy: 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).addClip()
        let total = max(1, Double(memory.total))
        var x = inner.minX
        for (bytes, alpha) in [(memory.app, 1.0), (memory.wired, 0.62), (memory.compressed, 0.36)] {
            let segment = inner.width * CGFloat(Double(bytes) / total)
            accent.withAlphaComponent(alpha).setFill()
            NSRect(x: x, y: inner.minY, width: segment, height: inner.height).fill()
            x += segment
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawLabel(_ label: String, value: String, x: CGFloat, width: CGFloat, color: NSColor, valueColor: NSColor) {
        let labelText = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .bold),
            .foregroundColor: color.withAlphaComponent(0.62),
            .kern: 0.4,
        ])
        labelText.draw(at: NSPoint(x: x, y: 9.5))
        let valueText = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: valueColor,
        ])
        valueText.draw(at: NSPoint(x: x, y: -0.5))
    }

    // MARK: Compact layout

    private static func drawCompact(snapshot: Snapshot, base: NSColor, accent: NSColor) -> NSImage {
        let letterWidth: CGFloat = 8, barWidth: CGFloat = 34, barHeight: CGFloat = 5.5
        return NSImage(size: NSSize(width: letterWidth + barWidth, height: height), flipped: false) { _ in
            let rows: [(String, CGFloat)] = [("C", 10.5), ("R", 2)]
            for (letter, y) in rows {
                NSAttributedString(string: letter, attributes: [
                    .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                    .foregroundColor: base.withAlphaComponent(0.7),
                ]).draw(at: NSPoint(x: 0, y: y - 2))

                let track = NSRect(x: letterWidth, y: y, width: barWidth, height: barHeight)
                base.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).addClip()
                if letter == "C" {
                    base.setFill()
                    NSRect(x: track.minX, y: y, width: barWidth * CGFloat(min(1, snapshot.cpu.total)), height: barHeight).fill()
                } else {
                    let memory = snapshot.memory
                    let total = max(1, Double(memory.total))
                    var x = track.minX
                    for (bytes, alpha) in [(memory.app, 1.0), (memory.wired, 0.62), (memory.compressed, 0.36)] {
                        let segment = barWidth * CGFloat(Double(bytes) / total)
                        accent.withAlphaComponent(alpha).setFill()
                        NSRect(x: x, y: y, width: segment, height: barHeight).fill()
                        x += segment
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

// MARK: - Status item

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor: Monitor
    private let store: SettingsStore
    private let log: ActivityLog
    private let openSettings: () -> Void
    private var debugReports = ProcessInfo.processInfo.environment["WAM_DEBUG"] == nil ? 0 : 3

    init(monitor: Monitor, store: SettingsStore, log: ActivityLog, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.store = store
        self.log = log
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        // Lets macOS remember where the user dragged the item.
        item.autosaveName = "DedotatedWamMeters"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
        }
        update(with: monitor.snapshot)
    }

    func update(with snapshot: Snapshot) {
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = MenuBarRenderer.image(snapshot: snapshot, settings: store.settings, dark: dark)
        let memory = snapshot.memory
        let summary = "CPU \(Int((snapshot.cpu.total * 100).rounded()))%, memory \(ByteFormat.string(memory.used)) of \(ByteFormat.string(memory.total)), pressure \(memory.pressure.label.lowercased())"
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
        if debugReports > 0 {
            // WAM_DEBUG=1: say where the item ended up, to tell "hidden by a menu bar manager" from "not drawn".
            debugReports -= 1
            let frame = button.window?.frame ?? .zero
            let screen = button.window?.screen?.frame ?? .zero
            FileHandle.standardError.write(Data("status item: visible=\(item.isVisible) frame=\(frame) screen=\(screen) image=\(button.image?.size ?? .zero) occluded=\(!(button.window?.occlusionState.contains(.visible) ?? false))\n".utf8))
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        // Built on demand and dropped on close, so the app stays small while idle.
        let view = PopoverView(
            monitor: monitor,
            store: store,
            log: log,
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        monitor.setDetailed(true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setDetailed(false)
        popover.contentViewController = nil
    }
}
