import Foundation

/// `~/.claude/plugins/installed_plugins.json` 의 entry 1개 (V2).
/// Multi-scope 지원: 같은 plugin id 가 user/project/local 에 동시 설치 가능.
///
/// Claude Code mirror: `schemas.ts:1562` `InstalledPluginsFileSchemaV2` 의 element.
public struct PluginInstallationEntry: Codable, Sendable, Equatable {
    public let scope: PluginScope
    /// project/local scope 일 때만 의미 있음.
    public let projectPath: String?
    /// 절대 경로 — `~/.claude/plugins/cache/<market>/<plugin>/<version>/`.
    public let installPath: String
    public let version: String?
    public let installedAt: Date?
    public let lastUpdated: Date?
    /// directory source 로 install 된 경우 nil (M0 spike Q10 검증).
    public let gitCommitSha: String?

    public init(
        scope: PluginScope,
        projectPath: String? = nil,
        installPath: String,
        version: String? = nil,
        installedAt: Date? = nil,
        lastUpdated: Date? = nil,
        gitCommitSha: String? = nil
    ) {
        self.scope = scope
        self.projectPath = projectPath
        self.installPath = installPath
        self.version = version
        self.installedAt = installedAt
        self.lastUpdated = lastUpdated
        self.gitCommitSha = gitCommitSha
    }
}

/// `~/.claude/plugins/installed_plugins.json` V2 schema.
/// Top-level 구조:
/// ```json
/// { "version": 2, "plugins": { "name@market": [InstallationEntry, ...] } }
/// ```
///
/// `version != 2` 인 파일을 만나면 init(from:) 에서 throw → 매니저 read-only mode 진입.
public struct InstalledPluginsFileV2: Codable, Sendable, Equatable {
    public let version: Int
    public let plugins: [String: [PluginInstallationEntry]]

    public init(plugins: [String: [PluginInstallationEntry]]) {
        self.version = 2
        self.plugins = plugins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let v = try container.decode(Int.self, forKey: .version)
        guard v == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported installed_plugins.json version \(v) — manager enters read-only mode"
            )
        }
        self.version = v
        self.plugins = try container.decode([String: [PluginInstallationEntry]].self, forKey: .plugins)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case plugins
    }
}

extension InstalledPluginsFileV2 {
    /// 스키마-호환 디코더. JSONCoding 헬퍼 위임.
    public static func decode(from data: Data) throws -> InstalledPluginsFileV2 {
        try JSONCoding.decoder().decode(InstalledPluginsFileV2.self, from: data)
    }

    /// 스키마-호환 인코더. JSONCoding 헬퍼 위임.
    public static func encode(_ value: InstalledPluginsFileV2) throws -> Data {
        try JSONCoding.encoder().encode(value)
    }
}
