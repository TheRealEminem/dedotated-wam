import AppKit
import SwiftUI
import WamCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: SettingsStore!
    private var log: ActivityLog!
    private var monitor: Monitor!
    private var statusItem: StatusItemController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = SettingsStore()
        log = ActivityLog()
        monitor = Monitor(store: store, log: log)
        statusItem = StatusItemController(monitor: monitor, store: store, log: log) { [weak self] in
            self?.showSettings()
        }
        monitor.onTick = { [weak self] snapshot in
            self?.statusItem.update(with: snapshot)
        }
        monitor.start()
    }

    /// Opening the app again while it is running (Finder, Spotlight, `open`) shows Settings.
    /// This is the way in when a menu bar manager has hidden the meters.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Dedotated Wam"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor, store: store, log: log))
            window.center()
            settingsWindow = window
        }
        monitor.setDetailed(true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        monitor.setDetailed(false)
        // Drop the SwiftUI tree so the idle app stays small.
        settingsWindow?.contentViewController = nil
        settingsWindow = nil
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-previews"), arguments.count > flag + 1 {
    // Developer aid: draws the UI with made-up numbers into PNG files, then exits.
    PreviewRenderer.run(outputDirectory: arguments[flag + 1])
    exit(0)
}

if arguments.contains("--print-snapshot") {
    // Developer aid: one reading of memory and the biggest apps as text, then exit.
    let store = SettingsStore(persist: false)
    let memory = MemorySampler.sample()
    print("memory: \(ByteFormat.string(memory.used)) of \(ByteFormat.string(memory.total)) (\(memory.usedPercent)%)"
        + " | app \(ByteFormat.string(memory.app)), wired \(ByteFormat.string(memory.wired)), compressed \(ByteFormat.string(memory.compressed)), cached \(ByteFormat.string(memory.cached))"
        + " | swap \(ByteFormat.string(memory.swapUsed)) | pressure \(memory.pressure.label)")
    let apps = Monitor(store: store, log: ActivityLog(persist: false)).scanApps()
    for app in apps.prefix(15) {
        let group = app.bundleID.flatMap { store.settings.groupIndex(forBundleID: $0) }.map { store.settings.groups[$0].name } ?? "-"
        print("  \(ByteFormat.string(app.footprint).padding(toLength: 9, withPad: " ", startingAt: 0)) \(app.name) [\(group)]\(app.isRegular ? "" : " (background)")")
    }
    let queue = TriagePlanner.queue(settings: store.settings, apps: apps, selfBundleID: AppPaths.bundleID)
    print("would close, in order: " + queue.prefix(8).map(\.app.name).joined(separator: ", "))
    exit(0)
}

// One copy is enough.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { exit(0) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
