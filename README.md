# Boring Notch: Stats and Tokens

A community fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) that adds system monitoring and Codex and Claude Code token usage to the notch interface. The original Home and Shelf features remain available, with Stats and Tokens added as separate tabs.

This fork is maintained by [Logan Popwell](https://github.com/loganpopwell) and is based on upstream commit `69c43e2`. It is an independent modification, not an official release from The Bored Team.

## Features

### System monitoring

The Stats tab displays CPU and memory usage, GPU utilization, storage usage, network upload and download speeds, and battery information. Expandable CPU and memory views rank processes by application. Battery details include estimated capacity health and cycle count when available.

The interface follows Boring Notch's existing dark styling, with compact summary cards and expandable detail views. System readings refresh while the tab is visible.

### Codex and Claude Code token usage

The Tokens tab uses [AI Token Meter](https://github.com/prefect12/codex-token-meter) for Codex aggregates and a usage-only local reader for Claude Code to display:

- All, Codex, and Claude Code source filters, plus filters by model maker (Anthropic, OpenAI) across both tools.
- Today, current calendar month, and retained lifetime local token usage.
- Monthly history and estimated API-equivalent cost in USD for both providers.
- Per-model token totals, usage percentages, estimated costs, and cost shares.
- A pricing chart and model detail view with input, output, cache-read, and cache-write rates and charges.
- Input, cached-input, and output token breakdowns.
- Pricing coverage, data freshness, and a separate account-lifetime total when available.

AI Token Meter must be installed to refresh Codex source data. Opening Tokens starts the meter in the background if it has stopped. The helper checks both local sources every 30 seconds while visible. Claude Code usage is decoded directly from assistant-message usage metadata under `.claude/projects`, including subagents. It decodes only model, timestamp, message identifiers, and numeric usage, ignores content, and deduplicates streamed messages and repeated files. Unchanged files use an in-memory metadata cache. No credentials or conversation content are decoded, retained, or transmitted. Usage stays local. The helper fetches only the public OpenRouter model-price catalog, without sending usage, model selections, prompts, or credentials. Prices refresh daily; a verified bundled price snapshot and a local price cache support offline use.

### Subscription limits

The Tokens tab's **Limits** view lists each Claude account pooled by a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) gateway, with 5-hour and weekly usage, reset times, routing priority, cooldowns, and which account answered last or would answer next, plus native Codex limits from its session files. A **Restart** button restarts the proxy's LaunchAgent.

The Tokens overview also shows the tightest limit of the Claude account in use and of Codex next to the token and cost totals. Limits are read only while the Tokens tab is open; nothing runs in the closed notch.

The proxy integration reads the management key from `~/.config/cliproxyapi/management-key` and connects only to `127.0.0.1`. Full account limits are requested only while the Limits view is open.

## Interpreting the readings

API-equivalent costs apply current standard rates from the [OpenRouter Models API](https://openrouter.ai/docs/api-reference/models/get-models) to recorded local usage. They do not represent subscription charges or historical invoices. Input means tokens sent to the model; output means tokens received. Cache reads and cache writes are already included in input, so the estimator subtracts them from uncached input before applying each rate. Claude cache writes use separate 5-minute and 1-hour rates.

The Models view shows each model's share of the selected period's tokens and estimated cost. Selecting a model opens its category-level token counts, USD per million rates, estimated charges, pricing source, and verification date. The Pricing view compares those rates across used models. Estimates exclude Fast mode, request-specific long-context surcharges, and tool fees because the aggregate reports do not retain the necessary request details. Unsupported prices remain unpriced. Spark uses GPT-5.3 Codex prices as an explicitly labeled proxy until a published Spark rate becomes available. Source cache counts that exceed input are capped for cost calculation while recorded totals remain visible.

Lifetime local usage covers retained meter history for Codex and retained local Claude Code files. Deleted or unretained history cannot be recovered. Missing sources are labeled unavailable, and combined totals are marked partial when one source cannot be read.

Per-application CPU usage uses 100% to represent one processor core. Memory totals can include shared pages counted in multiple processes. Battery health is a capacity estimate; the battery view shows application CPU activity for context rather than measured per-application battery drain. Hardware readings that are not exposed by macOS are shown as unavailable.

## Build and installation

Build this repository to use the Stats and Tokens tabs. Official upstream downloads do not include these additions.

See the [build and implementation notes](LOCAL_STATS.md) for build commands, signing requirements, and validation instructions. Local builds may require renewed Calendar and Reminders permissions.

The upstream automatic updater is disabled to prevent official releases from replacing the fork's changes. Upstream updates must be integrated and rebuilt manually.

## Upstream project and license

Boring Notch was created by [The Bored Team](https://github.com/TheBoredTeam/boring.notch). The [original project README](UPSTREAM_README.md) is retained for its documentation, contributor credits, and project links.

This fork retains the original [GPL-3.0 license](LICENSE) and [third-party notices](THIRD_PARTY_LICENSES).
