import AppKit
import SwiftUI
import WamCore

// MARK: - Drawing

/// Draws the little meters that live in the menu bar.
enum MenuBarRenderer {
    static let height: CGFloat = 18

    /// The colours one drawing pass uses.
    private struct Ink {
        /// Everything that is not a warning.
        var base: NSColor
        /// The memory meter: `base`, or orange or red when memory is tight.
        var memory: NSColor
        /// The battery meter: `base`, or orange or red when it is running low.
        var battery: NSColor
    }

    /// - Parameter dark: whether the menu bar is dark, which only matters when a warning colour
    ///   stops the image being a template.
    static func image(snapshot: Snapshot, settings: WamSettings, dark: Bool) -> NSImage {
        let battery = settings.showBattery ? snapshot.battery : nil
        let memorySeverity = settings.colorByPressure ? snapshot.severity : 0
        let batterySeverity = battery?.severity ?? 0
        // With no warning to show, a template image lets the system pick black or white by itself.
        let template = memorySeverity == 0 && batterySeverity == 0
        let base: NSColor = template ? .black : (dark ? .white : .black)
        func warning(_ severity: Int) -> NSColor {
            severity == 2 ? .systemRed : (severity == 1 ? .systemOrange : base)
        }
        let ink = Ink(base: base, memory: warning(memorySeverity), battery: warning(batterySeverity))

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
            image = drawWide(snapshot: snapshot, battery: battery, cpuValues: cpuValues, numbers: true, ink: ink)
        case .graphs:
            image = drawWide(snapshot: snapshot, battery: battery, cpuValues: cpuValues, numbers: false, ink: ink)
        case .compact:
            image = drawCompact(snapshot: snapshot, battery: battery, ink: ink)
        }
        image.isTemplate = template
        return image
    }

    // MARK: Wide layouts

    private static func drawWide(snapshot: Snapshot, battery: BatterySample?, cpuValues: [Double], numbers: Bool, ink: Ink) -> NSImage {
        let barWidth: CGFloat = 2, barGap: CGFloat = 1
        let graphWidth = CGFloat(cpuValues.count) * (barWidth + barGap) - barGap
        let textWidth: CGFloat = numbers ? 25 : 0
        let textGap: CGFloat = numbers ? 3 : 0
        let capsuleWidth: CGFloat = 30
        let batteryWidth: CGFloat = 25
        let blockGap: CGFloat = numbers ? 7 : 6
        var width = graphWidth + textGap + textWidth + blockGap + capsuleWidth + textGap + textWidth
        if battery != nil { width += blockGap + batteryWidth + textGap + textWidth }

        return NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            let base = ink.base
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
                drawLabel("CPU", value: percent(snapshot.cpu.total), x: x, color: base, valueColor: base)
                x += textWidth
            }
            x += blockGap

            // RAM: a capsule that fills up, shaded by what kind of memory it is.
            drawCapsule(memory: snapshot.memory, rect: NSRect(x: x, y: 3.5, width: capsuleWidth, height: 11), base: base, accent: ink.memory)
            x += capsuleWidth
            if numbers {
                x += textGap
                drawLabel("RAM", value: percent(snapshot.memory.usedFraction), x: x, color: base, valueColor: ink.memory)
                x += textWidth
            }

            // Battery: the familiar shape, with a bolt while plugged in.
            if let battery {
                x += blockGap
                drawBattery(battery, rect: NSRect(x: x, y: 3.5, width: batteryWidth, height: 11), base: base, accent: ink.battery)
                x += batteryWidth
                if numbers {
                    x += textGap
                    drawLabel(battery.isCharging ? "CHG" : (battery.onAC ? "AC" : "BAT"), value: "\(battery.percent)%", x: x, color: base, valueColor: ink.battery)
                }
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

    private static func drawBattery(_ battery: BatterySample, rect: NSRect, base: NSColor, accent: NSColor) {
        // Body, with a small terminal on the right.
        let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width - 2.5, height: rect.height)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        base.withAlphaComponent(0.55).setStroke()
        outline.stroke()
        base.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.5, y: rect.midY - 2, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()

        let inner = body.insetBy(dx: 2, dy: 2)
        let charge = NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * CGFloat(battery.fraction)), height: inner.height)
        accent.setFill()
        NSBezierPath(roundedRect: charge, xRadius: 1.5, yRadius: 1.5).fill()

        guard battery.onAC else { return }
        // A bolt with a clear halo, so it reads over both the filled and the empty part.
        let centre = NSPoint(x: body.midX, y: body.midY)
        let bolt = NSBezierPath()
        let points: [(CGFloat, CGFloat)] = [(1.2, 4.6), (-2.6, -0.7), (-0.3, -0.7), (-1.2, -4.6), (2.6, 0.7), (0.3, 0.7)]
        for (index, point) in points.enumerated() {
            let target = NSPoint(x: centre.x + point.0, y: centre.y + point.1)
            if index == 0 { bolt.move(to: target) } else { bolt.line(to: target) }
        }
        bolt.close()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.set()
        bolt.lineWidth = 2.2
        bolt.lineJoinStyle = .round
        bolt.stroke()
        bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
        base.setFill()
        bolt.fill()
    }

    private static func drawLabel(_ label: String, value: String, x: CGFloat, color: NSColor, valueColor: NSColor) {
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

    private static func drawCompact(snapshot: Snapshot, battery: BatterySample?, ink: Ink) -> NSImage {
        let letterWidth: CGFloat = 8, barWidth: CGFloat = 34
        // Two rows normally; three thinner ones when the battery is shown.
        let letters = battery == nil ? ["C", "R"] : ["C", "R", "B"]
        let barHeight: CGFloat = battery == nil ? 5.5 : 4
        let pitch: CGFloat = battery == nil ? 8.5 : 6
        let fontSize: CGFloat = battery == nil ? 7 : 5.5
        let base = ink.base

        return NSImage(size: NSSize(width: letterWidth + barWidth, height: height), flipped: false) { _ in
            for (row, letter) in letters.enumerated() {
                let y = (height - barHeight - 1.5) - CGFloat(row) * pitch
                let text = NSAttributedString(string: letter, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: base.withAlphaComponent(0.7),
                ])
                text.draw(at: NSPoint(x: 0, y: y + barHeight / 2 - text.size().height / 2))

                let track = NSRect(x: letterWidth, y: y, width: barWidth, height: barHeight)
                base.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).addClip()
                switch letter {
                case "C":
                    base.setFill()
                    NSRect(x: track.minX, y: y, width: barWidth * CGFloat(min(1, snapshot.cpu.total)), height: barHeight).fill()
                case "R":
                    let memory = snapshot.memory
                    let total = max(1, Double(memory.total))
                    var x = track.minX
                    for (bytes, alpha) in [(memory.app, 1.0), (memory.wired, 0.62), (memory.compressed, 0.36)] {
                        let segment = barWidth * CGFloat(Double(bytes) / total)
                        ink.memory.withAlphaComponent(alpha).setFill()
                        NSRect(x: x, y: y, width: segment, height: barHeight).fill()
                        x += segment
                    }
                default:
                    ink.battery.setFill()
                    NSRect(x: track.minX, y: y, width: barWidth * CGFloat(battery?.fraction ?? 0), height: barHeight).fill()
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
        let summary: String = "CPU \(Int((snapshot.cpu.total * 100).rounded()))%, memory \(ByteFormat.string(memory.used)) of \(ByteFormat.string(memory.total)), pressure \(memory.pressure.label.lowercased())"
            + (snapshot.battery.map { ", battery \($0.percent)% (\($0.stateLabel.lowercased()))" } ?? "")
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
