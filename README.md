# Boring Notch: Stats and Tokens

A community fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) that adds system monitoring and Codex token usage to the notch interface. The original Home and Shelf features remain available, with Stats and Tokens added as separate tabs.

This fork is maintained by [Logan Popwell](https://github.com/loganpopwell) and is based on upstream commit `69c43e2`. It is an independent modification, not an official release from The Bored Team.

## Features

### System monitoring

The Stats tab displays CPU and memory usage, GPU utilization, storage usage, network upload and download speeds, and battery information. Expandable CPU and memory views rank processes by application. Battery details include estimated capacity health and cycle count when available.

The interface follows Boring Notch's existing dark styling, with compact summary cards and expandable detail views. System readings refresh while the tab is visible.

### Codex token usage

The Tokens tab integrates with [AI Token Meter](https://github.com/prefect12/codex-token-meter) to display:

- Today, current calendar month, and lifetime local token usage.
- Monthly history and estimated API-equivalent cost in USD.
- Input, cached-input, and output token breakdowns.
- Pricing coverage, data freshness, and a separate account-lifetime total when available.

AI Token Meter must be installed and running to refresh the source data. The tab reads its local aggregate report every 30 seconds while visible. This integration does not read credentials or conversation logs, and it makes no network requests.

## Interpreting the readings

API-equivalent costs estimate what recorded usage would cost at the token prices used by AI Token Meter. They do not represent subscription charges. Unknown-model tokens are marked as unpriced, and lifetime local usage covers only the history retained by the meter.

Per-application CPU usage uses 100% to represent one processor core. Memory totals can include shared pages counted in multiple processes. Battery health is a capacity estimate; the battery view shows application CPU activity for context rather than measured per-application battery drain. Hardware readings that are not exposed by macOS are shown as unavailable.

## Build and installation

Build this repository to use the Stats and Tokens tabs. Official upstream downloads do not include these additions.

See the [build and implementation notes](LOCAL_STATS.md) for build commands, signing requirements, and validation instructions. Local builds may require renewed Calendar and Reminders permissions.

The upstream automatic updater is disabled to prevent official releases from replacing the fork's changes. Upstream updates must be integrated and rebuilt manually.

## Upstream project and license

Boring Notch was created by [The Bored Team](https://github.com/TheBoredTeam/boring.notch). The [original project README](UPSTREAM_README.md) is retained for its documentation, contributor credits, and project links.

This fork retains the original [GPL-3.0 license](LICENSE) and [third-party notices](THIRD_PARTY_LICENSES).
