# Dedotated Wam

macOS menu bar app: CPU and memory meters, plus automatic closing of apps under memory pressure.

## Build

- Built with SwiftPM and the Command Line Tools only. There is no Xcode project; do not add one.
- `Scripts/build-app.sh --run` builds, signs (ad hoc) and restarts the app. `Scripts/test.sh` runs the tests.
- `Scripts/build-app.sh --dmg` builds for Apple silicon and Intel and packs `dist/DedotatedWam-<version>.dmg` with its checksum. The version comes from `Resources/Info.plist`.
- Use `Scripts/test.sh`, not a bare `swift test`: without Xcode, `swift test` intermittently fails with "plugin for module 'TestingMacros' not found". The script passes the plugin folder explicitly.
- Do not use `@State`. In the current SDK it is a macro whose plugin ships only with full Xcode, so it fails to compile here. Use `@Local` (`Sources/DedotatedWam/Local.swift`) instead.
- Swift language mode is 5 on purpose (`Package.swift`).

## Layout

- `Sources/WamCore`: no UI. Samplers, `WamSettings`, `AppCatalog`, `ProcessCatalog`, `TriagePlanner` and `TriageEngine`. Anything that decides what gets closed belongs here and gets a test.
- `Sources/DedotatedWam`: AppKit status item and popover, SwiftUI views, `Monitor` (sampling loop and the only place apps are closed automatically).

## Rules that matter

- Auto-close must default to off (`WamSettings.mode`), and a test pins this.
- macOS memory pressure "Warning" alone must not trigger closing by default (`softOnPressureWarning`): a busy Mac sits at Warning for hours while working fine. A test pins this too.
- After any change to what gets closed or how, run `Scripts/drill.sh`. It is the only check that closes real processes, and it may close only its own throwaway targets.
- The sampling and triage loop runs on its own queue, not the main thread, so it keeps working when the UI is starved. Keep UI work out of `Monitor.tick`.
- Keep the idle footprint small: the popover and settings views are created on open and dropped on close.
- The catalog (`AppCatalog.swift`) is generic. Nothing about a particular person or machine goes in the repo; personal choices live in `~/Library/Application Support/DedotatedWam/settings.json`.
- When unsure which tier an app belongs in, pick the more protective one.
- A rule can name a background process instead of an app. It is an `AppRule` whose `bundleID` starts with `process:`; use `AppRule.process(named:)` and `processName`, never build the string by hand.
- Quit buttons in the popover must soft-lock anything protected (`WamSettings.isProtected`, `RunningProcess.isProtected`): a second, explicit click, never one.

## Checking UI changes

- `--render-previews <folder>` draws every menu bar style, the popover and each settings tab into PNGs with made-up data.
- `--print-snapshot` prints live readings and the current closing order.
- `--drill <bundle id | process:name> ...` runs the real monitor as if memory were critical, with in-memory settings that list only those targets. Use it through `Scripts/drill.sh`.
- `WAM_DEBUG=1` prints where the status item landed, which tells "hidden by a menu bar manager" from "not drawn".

## Download page and releases

- `docs/` is the public download page (GitHub Pages, from `main`). One file, `docs/index.html`, with its own look: black circuit board, gold contacts, LED meter. Screenshots there must come from `--render-previews`, never from the live app, and never the Priorities tab, which lists the real installed apps.
- The page's button links to `releases/latest/download/DedotatedWam.dmg`, so every release must carry that file as well as the versioned one and its `.sha256`. `Scripts/build-app.sh --dmg` makes all three.
- Before a release: bump both versions in `Resources/Info.plist`, run `Scripts/test.sh` and `Scripts/drill.sh`, then build the disk image.

## CI

None yet. If CI is added, it needs a macOS runner and should run `Scripts/test.sh` and `Scripts/build-app.sh`; a release should also run `Scripts/build-app.sh --dmg`. `Scripts/drill.sh` opens real apps, so it is a check for a Mac with a logged-in user, not for a runner.
