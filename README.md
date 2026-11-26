# Dedotated Wam

A macOS menu bar app that shows CPU and memory use as small live meters and, when memory runs out, closes apps for you in an order you choose, so the Mac never gets to the point where it is too choked to close anything by hand.

## What it does

- **Menu bar meters.** CPU as a row of bars (recent history, or one bar per core) and memory as a capsule that fills up, shaded by app, wired and compressed memory. The memory meter turns orange, then red, as memory gets tight. On a laptop a battery meter sits beside them (with a bolt while plugged in, orange or red when running low), so the system's own battery icon can be switched off. Three layouts: graphs with numbers, graphs only, compact stacked bars.
- **Popover.** Click the meters for the memory breakdown, swap, per-core CPU, and the biggest apps with their helper processes counted in (a browser is charged for its tabs). Hover an app to quit or force quit it. Protected apps (your "never close" groups and system pieces such as Finder) show a lock and ask you to confirm first.
- **Auto-close.** Off by default. In *Warn only* it tells you what it would close. In *Auto-close* it works through your groups until memory recovers:
  - **Stage 1** (memory tight): asks apps to quit nicely, one at a time, with a pause between each.
  - **Stage 2** (memory critical): apps in a "force if stuck" group that ignored the polite request are force quit.
- **Priorities.** Apps are sorted into ordered groups. Each group sets how its apps are closed (nicely only, nicely then force, force at once, never) and in what order (list order or biggest first). On first launch the installed apps are sorted into four suggested groups from a built-in catalog: *Close first*, *Close next*, *Last resort*, *Never close*.
- **Safety.** The app you are using is never closed, small apps are skipped, system apps are protected, and everything it does is written to an activity log.

## Build and run

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
Scripts/build-app.sh --run
```

To install it in `/Applications` (needed for *Open at login*):

```bash
Scripts/build-app.sh --install
```

Run the tests:

```bash
swift test
```

If the meters do not appear, a menu bar manager may have filed the new item in its hidden section. Expand it and drag the item out while holding Command. Until then, opening the app again (Finder, Spotlight) brings up its Settings window.

## Where things live

| Path | What |
|---|---|
| `Sources/WamCore` | Sampling, settings, the app catalog and the triage logic. No UI. |
| `Sources/DedotatedWam` | The menu bar app: meters, popover, settings window, closing apps. |
| `Tests/WamCoreTests` | Tests for the triage rules, the process roll-up and the catalog. |
| `Scripts/build-app.sh` | Builds and signs `build/Dedotated Wam.app`. |
| `~/Library/Application Support/DedotatedWam` | Your settings and the activity log. Not in the repo. |

## Developer aids

```bash
"build/Dedotated Wam.app/Contents/MacOS/DedotatedWam" --print-snapshot
```

prints one reading of memory, the biggest apps and the current closing order.

```bash
"build/Dedotated Wam.app/Contents/MacOS/DedotatedWam" --render-previews /tmp/wam-previews
```

draws the meters, popover and settings with made-up numbers into PNG files, for checking layout without touching real settings.
