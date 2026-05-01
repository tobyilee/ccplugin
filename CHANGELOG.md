# Changelog

All notable changes to **Claude Code Plugin Manager** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

When a major feature ships, bump the version and add a new entry — the version
lives in three places that must move together:

- `Packages/App/Sources/App/AppMain.swift` — `AppInfo.version` fallback.
- `Scripts/install-local.sh` — `APP_VERSION`.
- `README.md` / `README.ko.md` — the "Current version" badge near the top.

## [0.2.0] — 2026-04-30

### Added
- **MCPs tab** — manage installed MCP servers (disable / enable / remove).
  - Unified list across two sources: user-scope MCPs (from `~/.claude.json#mcpServers`,
    registered via `claude mcp add`) and plugin-bundled MCPs (from each plugin's
    `<installPath>/.mcp.json`).
  - Disable/enable applies to **all current projects** by writing into every
    `~/.claude.json#projects[*].disabledMcpServers` / `disabledMcpjsonServers` /
    `enabledMcpjsonServers` array, with the `enabledMcpjsonServers` allowlist
    updated for plugin-bundled MCPs to skip Claude Code's trust prompt.
  - Remove is offered only for user-scope MCPs and delegates to `claude mcp remove`.
    Plugin-bundled MCPs can only be disabled — uninstall the host plugin to remove
    them entirely.
  - `~/.claude.json` mutations go through the same FileLock + BackupService +
    atomic-rename + JSON passthrough discipline as `settings.json` writes, so
    unknown keys (e.g. `claudeAiMcpEverConnected`, per-project custom fields)
    survive every edit.
- **`~/.claude.json` watching** — FSEvents now also watches the user's
  `~/.claude.json` so `claude mcp add` from a terminal triggers an automatic UI
  refresh.
- **CHANGELOG.md** (this file) — versioning policy + history baseline.
- **`Current version` badge** in `README.md` and `README.ko.md`.

### Changed
- **Sidebar** — new **MCPs** entry between Hooks and Diagnostics with a live
  count badge.

### Schema additions
- New PluginCore types: `MCP`, `MCP.Source`, `MCPReader`, `MCPOperations`,
  `ClaudeJSONWriter` (with `MCPSourceKind`), and `ClaudePaths.userClaudeJSONFile`.

### Tests
- 11 new tests across `MCPReaderTests` and `ClaudeJSONWriterTests`. Total: 109
  PluginCore unit tests, all green.

### Known limitations
- Disable applies only to projects that already exist in `~/.claude.json`.
  Projects created by Claude Code *after* a disable will start with empty
  `disabledMcp*Servers` arrays and re-enable the MCP. Surfaced as a one-line
  footer in the MCPs tab.
- `.mcpb` bundle MCPs are not yet enumerated (PRD §F lists this as a third
  source — punted until a plugin in the wild uses it).

## [0.1.0] — 2026-04 (baseline)

Initial milestone-complete release covering M0 → M4 plus the UX iteration pass.
This entry is reconstructed from milestone status in `README.md`; for finer
granularity see git history before this changelog existed.

### Added
- **M0** — spike + infrastructure (CLI surface validation, lockfile policy).
- **M1** — read-only inventory: Installed / Marketplaces / Browse tabs with
  FSEvents auto-refresh.
- **M2** — marketplace mutations: Add / Refresh / Remove / Auto-Update toggle,
  FileLock, BackupService.
- **M3** — plugin lifecycle: install / uninstall / enable / disable / update,
  ReloadHint banner.
- **M4** — User Assets / Hooks / Diagnostics tabs, Orphaned-Cache cleanup.
- UX iteration — by-marketplace grouping, always-visible search, plugin /
  marketplace version display.

[0.2.0]: #020--2026-04-30
[0.1.0]: #010--2026-04-baseline
