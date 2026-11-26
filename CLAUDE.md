# Dedotated Wam

macOS menu bar app: CPU and memory meters, plus automatic closing of apps under memory pressure.

## Build

- Built with SwiftPM and the Command Line Tools only. There is no Xcode project; do not add one.
- `Scripts/build-app.sh --run` builds, signs (ad hoc) and restarts the app. `Scripts/test.sh` runs the tests.
- Use `Scripts/test.sh`, not a bare `swift test`: without Xcode, `swift test` intermittently fails with "plugin for module 'TestingMacros' not found". The script passes the plugin folder explicitly.
- Do not use `@State`. In the current SDK it is a macro whose plugin ships only with full Xcode, so it fails to compile here. Use `@Local` (`Sources/DedotatedWam/Local.swift`) instead.
- Swift language mode is 5 on purpose (`Package.swift`).

## Layout

- `Sources/WamCore`: no UI. Samplers, `WamSettings`, `AppCatalog`, `ProcessCatalog`, `TriagePlanner` and `TriageEngine`. Anything that decides what gets closed belongs here and gets a test.
- `Sources/DedotatedWam`: AppKit status item and popover, SwiftUI views, `Monitor` (sampling loop and the only place apps are closed automatically).

## Rules that matter

- Auto-close must default to off (`WamSettings.mode`), and a test pins this.
- The sampling and triage loop runs on its own queue, not the main thread, so it keeps working when the UI is starved. Keep UI work out of `Monitor.tick`.
- Keep the idle footprint small: the popover and settings views are created on open and dropped on close.
- The catalog (`AppCatalog.swift`) is generic. Nothing about a particular person or machine goes in the repo; personal choices live in `~/Library/Application Support/DedotatedWam/settings.json`.
- When unsure which tier an app belongs in, pick the more protective one.
- A rule can name a background process instead of an app. It is an `AppRule` whose `bundleID` starts with `process:`; use `AppRule.process(named:)` and `processName`, never build the string by hand.
- Quit buttons in the popover must soft-lock anything protected (`WamSettings.isProtected`, `RunningProcess.isProtected`): a second, explicit click, never one.

## Checking UI changes

- `--render-previews <folder>` draws every menu bar style, the popover and each settings tab into PNGs with made-up data.
- `--print-snapshot` prints live readings and the current closing order.
- `WAM_DEBUG=1` prints where the status item landed, which tells "hidden by a menu bar manager" from "not drawn".

## CI

None yet. The repo is private, so runner minutes are not free; if CI is added, it needs a macOS runner and should run `Scripts/test.sh` and `Scripts/build-app.sh`.
