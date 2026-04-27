import Foundation

/// `<installPath>/.claude-plugin/plugin.json` 의 매니저 read-only mirror.
///
/// PRD §7 + Claude Code `schemas.ts:884` `PluginManifestSchema` 의 presentation subset.
/// M1 inventory 행 표시에 필요한 필드만 노출. component 카운트는 별도 디렉토리 스캔
/// (`PluginManifestReader.countComponents`) 으로 합성 — manifest 의 commands/agents/skills/hooks
/// 필드는 string-array / dict / file-ref 의 union 이라 strict 미러링이 cost-효율적이지 않음.
///
/// 모르는 키는 Codable 기본 동작으로 무시. 의도적으로 `Decodable` 만 채택 (재인코딩 금지).
public struct PluginManifest: Decodable, Sendable, Equatable {
    public let name: String
    public let version: String?
    public let description: String?
    public let author: PluginAuthor?
    public let license: String?
    public let keywords: [String]?
    public let homepage: String?
    public let repository: String?

    public init(
        name: String,
        version: String? = nil,
        description: String? = nil,
        author: PluginAuthor? = nil,
        license: String? = nil,
        keywords: [String]? = nil,
        homepage: String? = nil,
        repository: String? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.license = license
        self.keywords = keywords
        self.homepage = homepage
        self.repository = repository
    }
}

/// `plugin.json` 의 `author` 필드 — 두 형태 모두 지원:
/// - 문자열: `"author": "Toby Lee"`
/// - 객체:   `"author": { "name": "Toby Lee", "email": "..." }`
public struct PluginAuthor: Decodable, Sendable, Equatable {
    public let name: String
    public let email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case email
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self.name = s
            self.email = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
    }
}
