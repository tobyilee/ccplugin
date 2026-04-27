import Foundation

/// 한 플러그인이 제공하는 component 개수 합계.
///
/// PRD §7.4 기준. M1 inventory 펼침 뷰에 표시.
/// CLI 는 `mcpServers` 만 노출하므로 나머지 카운트는 디스크에서만 합성 가능.
public struct ComponentCounts: Sendable, Equatable {
    public let commands: Int
    public let agents: Int
    public let skills: Int
    public let hooks: Int
    public let mcpServers: Int
    public let lspServers: Int

    public init(
        commands: Int = 0,
        agents: Int = 0,
        skills: Int = 0,
        hooks: Int = 0,
        mcpServers: Int = 0,
        lspServers: Int = 0
    ) {
        self.commands = commands
        self.agents = agents
        self.skills = skills
        self.hooks = hooks
        self.mcpServers = mcpServers
        self.lspServers = lspServers
    }

    public static let zero = ComponentCounts()
}

/// `<installPath>/.claude-plugin/plugin.json` 디코드 + 표준 component 디렉토리 카운트.
///
/// - `loadManifest(at:)`: presentation 필드 (name/version/description 등) 만.
/// - `countComponents(at:)`: 디렉토리 + 부속 JSON 파일 스캔으로 카운트.
///   누락은 0 으로 처리 (PRD §F1.1 "cache 누락 시 카운트는 빈 값 + warning 배지").
public actor PluginManifestReader {

    public enum ReaderError: Error, Sendable {
        case manifestNotFound(URL)
        case readFailed(URL, underlying: Error)
        case decodeFailed(URL, underlying: Error)
    }

    public init() {}

    public func loadManifest(at installPath: URL) async throws -> PluginManifest {
        let url = installPath
            .appending(path: ".claude-plugin", directoryHint: .isDirectory)
            .appending(path: "plugin.json", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.manifestNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReaderError.readFailed(url, underlying: error)
        }
        do {
            return try JSONCoding.decoder().decode(PluginManifest.self, from: data)
        } catch {
            throw ReaderError.decodeFailed(url, underlying: error)
        }
    }

    /// 디렉토리 + 부속 JSON 을 스캔하여 component 개수 추정.
    ///
    /// 표준 매핑:
    /// - `commands/*.md`        → commands 카운트
    /// - `agents/*.md`          → agents 카운트
    /// - `skills/<name>/SKILL.md` 가 존재하는 디렉토리 → skills 카운트
    /// - `hooks/hooks.json` 의 모든 event 배열 길이 합 → hooks 카운트
    /// - `.mcp.json` 의 `mcpServers` 객체 키 수 → mcpServers 카운트
    /// - `.lsp.json` 의 `lspServers` 객체 키 수 → lspServers 카운트
    ///
    /// 파일/디렉토리 누락 시 해당 항목 0. throw 하지 않음 — caller 가 빈 카운트 + warning 배지로 처리.
    public func countComponents(at installPath: URL) async -> ComponentCounts {
        ComponentCounts(
            commands: countMarkdownFiles(in: installPath.appending(path: "commands", directoryHint: .isDirectory)),
            agents: countMarkdownFiles(in: installPath.appending(path: "agents", directoryHint: .isDirectory)),
            skills: countSkillDirs(in: installPath.appending(path: "skills", directoryHint: .isDirectory)),
            hooks: countHookEntries(at: installPath.appending(path: "hooks/hooks.json", directoryHint: .notDirectory)),
            mcpServers: countDictKeys(at: installPath.appending(path: ".mcp.json", directoryHint: .notDirectory), key: "mcpServers"),
            lspServers: countDictKeys(at: installPath.appending(path: ".lsp.json", directoryHint: .notDirectory), key: "lspServers")
        )
    }

    private func countMarkdownFiles(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.count(where: { $0.pathExtension.lowercased() == "md" })
    }

    private func countSkillDirs(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.count(where: { entry in
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else { return false }
            let skillFile = entry.appending(path: "SKILL.md", directoryHint: .notDirectory)
            return fm.fileExists(atPath: skillFile.path)
        })
    }

    private func countHookEntries(at file: URL) -> Int {
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        // 두 가지 wrapping 모두 허용: { "hooks": { event: [...] } } 또는 raw { event: [...] }.
        let eventDict = (root["hooks"] as? [String: Any]) ?? root
        return eventDict.values
            .compactMap { ($0 as? [Any])?.count }
            .reduce(0, +)
    }

    private func countDictKeys(at file: URL, key: String) -> Int {
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = root[key] as? [String: Any]
        else { return 0 }
        return dict.count
    }
}
