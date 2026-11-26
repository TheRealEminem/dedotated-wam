import AppKit

// A throwaway target for Scripts/drill.sh: holds some memory and waits to be closed.
//
//   polite    an app that quits when asked
//   stubborn  an app that refuses to quit, so it has to be force quit; it also starts a "hog"
//   hog       a plain background process with no window and no app behind it
//
// The role comes from the first argument, or from the app's Info.plist. Every role exits by
// itself after two minutes, so nothing is left behind if a drill is interrupted.

let role = CommandLine.arguments.dropFirst().first
    ?? (Bundle.main.object(forInfoDictionaryKey: "WamDrillRole") as? String)
    ?? "hog"

// Fill the memory with noise: zeros would be compressed away to almost nothing.
let size = 160 * 1_048_576
let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
var noise: UInt64 = 0x9E37_79B9_7F4A_7C15
for offset in stride(from: 0, to: size, by: 8) {
    noise = noise &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    block.storeBytes(of: noise, toByteOffset: offset, as: UInt64.self)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(0) }

if role == "hog" {
    dispatchMain()
}

final class Delegate: NSObject, NSApplicationDelegate {
    private var hog: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard role == "stubborn" else { return }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wamdrillhog")
        process.arguments = ["hog"]
        try? process.run()
        hog = process
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        role == "stubborn" ? .terminateCancel : .terminateNow
    }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
