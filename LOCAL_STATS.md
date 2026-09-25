# Stats tab fork

BoringNotch Stats customization, based on upstream commit `69c43e2`.

Tab order is Home, Shelf (file drop), Stats. Home/calendar is preserved. The header exposes the tabs even when the file shelf is empty; disabling Shelf still leaves Home and Stats available. Compact player mode retains upstream behavior and does not show tabs.

Stats displays CPU, RAM, GPU, network, startup-volume storage, and battery. Click a card for details. CPU has a 30-sample trace; the footer opens Activity Monitor. Sampling runs on a serial utility queue once per second only while the stats view is visible. Per-app CPU and resident memory use the existing read-only XPC helper, grouped by app bundle. It needs no administrator rights, network requests, or third-party service. Details expand the notch, and returning to Overview restores its compact size. Battery details show CPU activity as context, not measured per-app battery drain.

CPU uses deltas of Mach CPU ticks, normalized across cores. Memory excludes file-backed cache and purgeable pages and includes compressed physical storage, so it can differ slightly from Activity Monitor's snapshot. Network sums active en* Wi-Fi/Ethernet counters and excludes virtual interfaces to avoid counting VPN traffic twice. Interface changes/reset counters are not treated as spikes. GPU reads driver-exposed IOAccelerator utilization and displays unavailable when absent. Storage uses the home volume's capacity and available bytes. Battery uses IOKit power sources; health is raw maximum capacity divided by design capacity, with cycle count where exposed. Thermal state is macOS's qualitative state, not a Celsius temperature. Fan RPM and temperature sensors are not included.

Build:

```sh
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=281 MARKETING_VERSION=2.8-beta.0-stats.2
xcrun swiftc Shared/SystemStatsReader.swift Shared/ProcessStatsSnapshot.swift BoringNotchXPCHelper/ProcessStatsReader.swift Tests/main.swift -o /tmp/boring-stats-check
/tmp/boring-stats-check
```

The Sparkle updater is not started in this fork to prevent an upstream update replacing the customization. Integrate upstream changes and rebuild manually. The build command above produces unsigned output. For local installation, sign the app and its nested helper with the appropriate entitlements, and keep a backup of the previous app and preferences.

Signing must preserve the original app and XPC helper entitlements. Sign nested code first, then the helper with its original entitlements, then the main app with its original entitlements. Verify with `codesign --verify --deep --strict`. Do not replace a running app.

Verification: Release build and standalone sampling tests passed, including Mach tick conversion against a busy single-thread process. Installed app UI verified CPU and RAM rankings, upload/download detail, battery health and cycles, expansion/back navigation, and calendar events after restoring the existing permission. Current SDK builds include the full-access Calendar and Reminders usage-description keys. Per-app CPU uses Mach timebase conversion and 100% represents one core.


## Tokens tab

Tab order is Home, Shelf, Stats, Tokens. Tokens reads the installed [AI Token Meter](https://github.com/prefect12/codex-token-meter) aggregate `machine-usage-history.json` through the existing XPC helper. This is an integration with its version 1 report schema, not a separate log scanner. Keep AI Token Meter running to refresh the underlying history; the tab reloads its report every 30 seconds while visible and includes an Open Meter button. A last-scan indicator turns orange after one hour. Missing or incompatible reports show an explicit unavailable state.

Today and calendar-month boundaries follow the meter's recorded timezone. Lifetime means all retained local daily records, not guaranteed complete account history. Account lifetime is displayed separately when the meter has it. API-equivalent USD sums the meter's estimates without maintaining an independent price table. Unknown-model tokens reduce priced coverage; fully unpriced usage is labeled Unpriced. These are estimates, not subscription bills or savings. Cached input is already part of input, and reasoning output is not added again. Older source cache counts can exceed reported input; these are retained and flagged without changing token totals or the meter's cost estimates. Only aggregate counts and estimates cross into the notch; the integration does not read credentials, prompts, or raw conversations, and performs no network requests.

Token-reader checks use synthetic fixtures, with optional local integration validation:

```sh
xcrun swiftc Shared/TokenUsageSnapshot.swift BoringNotchXPCHelper/TokenUsageReader.swift Tests/Tokens/main.swift -o /tmp/boring-token-check
/tmp/boring-token-check
/tmp/boring-token-check --live
```
