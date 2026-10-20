# Stats tab fork

BoringNotch Stats customization, based on upstream commit `69c43e2`.

Tab order is Home, Shelf (file drop), Stats. Home/calendar is preserved. The header exposes the tabs even when the file shelf is empty; disabling Shelf still leaves Home and Stats available. Compact player mode retains upstream behavior and does not show tabs.

Stats displays CPU, RAM, GPU, network, startup-volume storage, and battery. Click a card for details. CPU has a 30-sample trace; the footer opens Activity Monitor. Sampling runs on a serial utility queue once per second only while the stats view is visible. Per-app CPU and resident memory use the existing read-only XPC helper, grouped by app bundle. It needs no administrator rights, network requests, or third-party service. Details expand the notch, and returning to Overview restores its compact size. Battery details show CPU activity as context, not measured per-app battery drain.

CPU uses deltas of Mach CPU ticks, normalized across cores. Memory excludes file-backed cache and purgeable pages and includes compressed physical storage, so it can differ slightly from Activity Monitor's snapshot. Network sums active en* Wi-Fi/Ethernet counters and excludes virtual interfaces to avoid counting VPN traffic twice. Interface changes/reset counters are not treated as spikes. GPU reads driver-exposed IOAccelerator utilization and displays unavailable when absent. Storage uses the home volume's capacity and available bytes. Battery uses IOKit power sources; health is raw maximum capacity divided by design capacity, with cycle count where exposed. Thermal state is macOS's qualitative state, not a Celsius temperature. Fan RPM and temperature sensors are not included.

Build:

```sh
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=285 MARKETING_VERSION=2.8-beta.0-stats.6
xcrun swiftc Shared/SystemStatsReader.swift Shared/ProcessStatsSnapshot.swift BoringNotchXPCHelper/ProcessStatsReader.swift Tests/main.swift -o /tmp/boring-stats-check
/tmp/boring-stats-check
```

The Sparkle updater is not started in this fork to prevent an upstream update replacing the customization. Integrate upstream changes and rebuild manually. The build command above produces unsigned output. For local installation, sign the app and its nested helper with the appropriate entitlements, and keep a backup of the previous app and preferences.

Signing must preserve the original app and XPC helper entitlements. Sign nested code first, then the helper with its original entitlements, then the main app with its original entitlements. Verify with `codesign --verify --deep --strict`. Do not replace a running app.

Verification: Release build and standalone sampling tests passed, including Mach tick conversion against a busy single-thread process. Installed app UI verified CPU and RAM rankings, upload/download detail, battery health and cycles, expansion/back navigation, and calendar events after restoring the existing permission. Current SDK builds include the full-access Calendar and Reminders usage-description keys. Per-app CPU uses Mach timebase conversion and 100% represents one core.


## Tokens tab

Tab order is Home, Shelf, Stats, Tokens. Codex reads the installed [AI Token Meter](https://github.com/prefect12/codex-token-meter) `machine-usage-history.json` version 1 through the existing XPC helper. Claude Code reads assistant-message usage metadata from local `.claude/projects/**/*.jsonl`, including subagents. Session files are append-only, so each file is read from the end of its last complete line, in 32 MB chunks; an unfinished final record waits for its newline, and a replaced file is read again from the start. There is no per-file size cap below 4 GB. The first scan of a large history takes several seconds; later scans take tens of milliseconds while the helper stays alive. The UI waits up to 45 seconds for a first reading and keeps the previous reading if a later refresh is slow. Only model, timestamp, message IDs and numeric usage are decoded, without content or credentials. Message IDs deduplicate repeated streaming entries and files, retaining the largest completed usage. The parent `cache_creation_input_tokens` equals the total of duration subtypes and is counted once. The 1-hour subtype is priced at its own rate; remaining writes use the default 5-minute rate, including legacy records without a duration breakdown. This corrects the meter scanner's parent-plus-subtype double count. Unchanged files use an in-memory metadata cache keyed by modification date and size. Missing or partially unreadable sources are explicit. Unsupported Codex schemas show unavailable. Claude metadata is never exported or persisted by this integration.

All, Codex, and Claude Code filters share Today, This month, Lifetime, and monthly history. Combined totals add each local source once, and missing sources produce an explicit partial-total notice. The UI starts the installed meter quietly when it is stopped, with a one-minute retry interval, and reloads reports every 30 seconds while visible. Freshness follows each source's scan time (the older scan for combined totals), with an orange indicator after one hour. The manual refresh and Open Meter controls remain available. Claude refreshes independently of the meter.

Today and calendar-month boundaries follow the meter's recorded timezone. Lifetime means retained local daily records, not complete account history; Claude includes all retained local usage files. Codex account lifetime is displayed separately.

Per-model usage comes from Codex daily `modelBreakdown` records and normalized Claude assistant usage. Summaries, monthly history, model shares, and category charges all use the same current price snapshot so costs reconcile. Unattributed token counts remain explicit rows. The independent pricing reader uses the public OpenRouter model catalog for every provider, with exact model IDs and deterministic spelling rewrites only: Anthropic dash versions become dots (`claude-opus-5-5` → `claude-opus-5.5`), dated snapshots and `[1m]`-style annotations are dropped, and thinking or reasoning-effort suffixes (`-high`, `-thinking`) price at the base model. Bare family aliases (`opus`, `sonnet`) price at the newest catalog model of that family and are labeled "alias price". There is no successor-model guessing. The model maker (`vendor`) comes from the model name, not the tool that logged it, so a model routed through a local proxy (for example GPT through Claude Code) is priced and filtered as the right company. The Anthropic and OpenAI pills filter usage by maker across both tools. Prices are USD per million tokens; public per-token prices are converted by multiplying by one million. A bundled public snapshot verified on 2026-10-01 UTC and a price-only cache at `Library/Application Support/BoringNotch/token-prices.json` support offline operation. HTTPS catalog refreshes occur daily, with failed refresh attempts limited to once every five minutes. Network requests send no usage, selected model IDs, prompts, credentials, or private records. The Claude reader decodes only usage metadata, without conversation content or credentials.

Models shows tokens, token share, and estimated USD for each model in Today, This month, or Lifetime. Pricing compares input, cache-read, output, 5-minute cache-write, and 1-hour cache-write rates. Selecting a model shows category counts, rates, charges, cost share, pricing provenance, and the checked date. Each day's cache read/write tokens are subtracted from input before pricing fresh input; reasoning output is already included in output. Inconsistent cache counts are capped to input for estimates, flagged, and retained in raw recorded totals. Known category charges are summed; missing category prices reduce coverage. Unknown models stay unpriced. Spark uses an explicit proxy based on GPT-5.3 Codex rates, labeled in both model and price views. Standard API estimates at current rates exclude subscription billing, Fast mode, per-request long-context surcharges, and tool fees.


Token-reader checks use synthetic fixtures, with optional local integration validation:

```sh
xcrun swiftc Shared/AIStatusSnapshot.swift Shared/TokenUsageSnapshot.swift BoringNotchXPCHelper/TokenPricingCatalog.swift BoringNotchXPCHelper/TokenUsageReader.swift BoringNotchXPCHelper/ClaudeLocalUsageReader.swift BoringNotchXPCHelper/AIStatusReader.swift Shared/BillingReportSnapshot.swift BoringNotchXPCHelper/BillingReportReader.swift Tests/Tokens/main.swift -o /tmp/boring-token-check
/tmp/boring-token-check
/tmp/boring-token-check --live
```

Local build 283 verification: Release compilation and synthetic/live token checks passed. Independent raw-field sums matched Claude message-ID deduplication using identical file snapshots. Installed main/helper checksums, strict signatures, and preferences were verified. Live UI verified model shares, estimated USD, category charges, Claude 1-hour writes, combined pricing chart, and Spark proxy provenance. Home calendar events, Calendar/Reminders lists, and changing Stats readings were verified after installation.


## AI limits

The XPC helper reads account limits through `AIStatusReader`:

- **Claude accounts pooled by CLIProxyAPI.** The helper reads the management key from `~/.config/cliproxyapi/management-key` (owner-only file) and the port from `config.yaml` (default 8317), and talks only to `http://127.0.0.1:<port>/v0/management/`. Every 30 seconds it reads `auth-files`, which carries each Claude login's priority, status, cooldowns, recent request buckets, and the `Anthropic-Ratelimit-Unified-*` headers the proxy recorded from that account's last response. Header readings make no upstream request. The Codex `id_token` field is never decoded.
- **Full limits.** Only while Tokens › Limits is open, the helper asks Anthropic's usage endpoint for each account through the proxy's `api-call` (the same call the CLIProxy Quota page makes), at most every two minutes. These add weekly and model-scoped weekly windows. Readings stay valid for ten minutes; newer header readings replace the 5-hour value.
- **Native Codex.** The newest `token_count` rate-limit record in the last three days of `~/.codex/sessions` files. Only those lines are decoded.
- **Restart.** The helper finds the LaunchAgent whose program is `cliproxyapi` and runs `launchctl kickstart -k`. This clears stalled upstream connections after a network change.

Limits are polled only while the Tokens tab is open: every 30 seconds for the overview summary cards, every 45 seconds with full limits while Limits is open. The overview's Claude card follows the account that most recently answered through the proxy while it is still usable, otherwise the highest-priority usable account. Colors are mint below 75%, orange from 75%, and red from 95% or at the limit.

The closed-notch quota ring, its alerts, and Settings › AI were removed on 2026-10-19 because they were unused; their preference keys are no longer read.

## Tokens tab layout

Sections are Overview, Models, Pricing, History, and Limits, with source and maker filters and a Today/This month/Lifetime control below. Every section uses the same content height, so the notch stays at 320 pt while the tab is open. Overview shows tokens, estimated cost, the Claude and Codex limit cards, a stacked bar of new input, cache reads and output, and the top three models. History is a bar chart of the last 12 months; hover a bar for its totals.

Local build 284 verification: synthetic and live token and quota checks passed, Release build succeeded, installed ad-hoc signatures verified with `codesign --verify --deep --strict` using the previous build's app and helper entitlements, and the closed-notch ring rendered. The previous build and preferences were backed up under `~/Library/Application Support/BoringNotch/backups/`.

## Billing tab

Added 2026-10-19 (build 285). `BillingView.swift` (Tabs, explicit project reference) renders the dashboard's notch feed; `BillingReportReader.swift` in the helper fetches it, and `Shared/BillingReportSnapshot.swift` holds the decoded model. The feed is `lumacore-dashboard` `src/app/api/internal/billing/notch/route.ts`, built by the same `reportOverview()` as the report page's Overview tab. The key is a random per-device key listed in the dashboard's `BILLING_FEED_TOKENS` (Vercel production, sensitive), stored owner-only at `~/.config/lumacore/notch-billing-key`; `scripts/install-billing-key.sh` manages it. (Vercel sensitive values can't be read back, so the HMAC-derived internal scope keys weren't usable.) The LumaCore Revenue Apple TV app reads the same snapshot from `/api/internal/billing/tv` with its own key. Feed version 1; the reader refuses other versions.

