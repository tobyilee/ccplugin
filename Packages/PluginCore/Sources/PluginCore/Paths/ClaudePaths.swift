import Foundation

/// `~/.claude/` 의 표준 경로 해석.
/// `CLAUDE_CONFIG_DIR` 환경변수 가 있으면 우선.
public enum ClaudePaths {
    /// Claude config 루트. 기본 `~/.claude/`.
    public static var configDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// `<configDir>/plugins/`.
    public static var pluginsDir: URL {
        configDir.appending(path: "plugins", directoryHint: .isDirectory)
    }

    /// `<configDir>/plugins/installed_plugins.json`.
    public static var installedPluginsFile: URL {
        pluginsDir.appending(path: "installed_plugins.json", directoryHint: .notDirectory)
    }

    /// `<configDir>/plugins/known_marketplaces.json`.
    public static var knownMarketplacesFile: URL {
        pluginsDir.appending(path: "known_marketplaces.json", directoryHint: .notDirectory)
    }

    /// `<configDir>/plugins/blocklist.json`.
    public static var blocklistFile: URL {
        pluginsDir.appending(path: "blocklist.json", directoryHint: .notDirectory)
    }

    /// `<configDir>/plugins/marketplaces/`.
    public static var marketplacesDir: URL {
        pluginsDir.appending(path: "marketplaces", directoryHint: .isDirectory)
    }

    /// `<configDir>/plugins/cache/`.
    public static var cacheDir: URL {
        pluginsDir.appending(path: "cache", directoryHint: .isDirectory)
    }

    /// User-scope settings.json — `<configDir>/settings.json`.
    public static var userSettingsFile: URL {
        configDir.appending(path: "settings.json", directoryHint: .notDirectory)
    }

    /// Claude Code 의 사용자 환경설정 파일 — `~/.claude.json`.
    /// `mcpServers` (user-scope) 와 `projects[<path>].disabledMcp*Servers` 가 여기 산다.
    /// `configDir` 와 별개의 파일 — sibling 위치.
    public static var userClaudeJSONFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude.json", directoryHint: .notDirectory)
    }
}
