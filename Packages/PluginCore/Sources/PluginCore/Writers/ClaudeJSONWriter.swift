import Foundation

/// `~/.claude.json` 의 매니저-소관 필드 mutation.
///
/// `SettingsWriter` 와 동일한 invariant 와 안전성 패턴 (모르는 키 보존, FileLock,
/// BackupService snapshot, atomic rename) — 다만 대상 파일이 `~/.claude.json`.
///
/// MCP 관리 전용:
/// - `setMCPEnabledEverywhere`: 모든 현재 프로젝트의 disable 배열 일괄 편집.
/// - `removeUserScopeMCP`: top-level `mcpServers` 에서 키 제거.
public actor ClaudeJSONWriter {

    public enum WriterError: Error, Sendable {
        case fileMissing(URL)
        case parseFailed(URL, message: String)
        case writeFailed(URL, message: String)
    }

    /// MCP source 와 동치인 작은 enum — schema 가 PluginCore 안에서 self-contained.
    public enum MCPSourceKind: Sendable {
        case user
        case pluginJSON
    }

    private let fileURL: URL
    private let lock: FileLock
    private let backup: BackupService

    public init(
        fileURL: URL = ClaudePaths.userClaudeJSONFile,
        backup: BackupService = BackupService()
    ) {
        self.fileURL = fileURL
        self.lock = FileLock(target: fileURL)
        self.backup = backup
    }

    /// 모든 기존 프로젝트의 disable 배열에 `name` 을 일괄 추가/제거.
    ///
    /// - source `.user`: `disabledMcpServers` 만 편집.
    /// - source `.pluginJSON`: `disabledMcpjsonServers` 와 `enabledMcpjsonServers` 모두 편집
    ///   (enable 시 prompt 회피용으로 enabled 배열에도 추가).
    ///
    /// 미래에 새로 만들어질 프로젝트 항목은 빈 배열로 시작 — UI 가 footer note 로 안내.
    public func setMCPEnabledEverywhere(
        name: String,
        source: MCPSourceKind,
        enabled: Bool
    ) async throws {
        try await mutate { root in
            var projects = (root["projects"] as? [String: Any]) ?? [:]
            for (projectPath, raw) in projects {
                var entry = (raw as? [String: Any]) ?? [:]
                switch source {
                case .user:
                    var disabled = (entry["disabledMcpServers"] as? [String]) ?? []
                    if enabled {
                        disabled.removeAll { $0 == name }
                    } else if !disabled.contains(name) {
                        disabled.append(name)
                    }
                    entry["disabledMcpServers"] = disabled

                case .pluginJSON:
                    var disabled = (entry["disabledMcpjsonServers"] as? [String]) ?? []
                    var enabledList = (entry["enabledMcpjsonServers"] as? [String]) ?? []
                    if enabled {
                        disabled.removeAll { $0 == name }
                        if !enabledList.contains(name) { enabledList.append(name) }
                    } else {
                        enabledList.removeAll { $0 == name }
                        if !disabled.contains(name) { disabled.append(name) }
                    }
                    entry["disabledMcpjsonServers"] = disabled
                    entry["enabledMcpjsonServers"] = enabledList
                }
                projects[projectPath] = entry
            }
            root["projects"] = projects
        }
    }

    /// `~/.claude.json#mcpServers` 에서 user-scope 등록 제거.
    /// (CLI 의 `claude mcp remove <name>` 과 동일한 효과를 직접 mutation 으로 수행.)
    public func removeUserScopeMCP(name: String) async throws {
        try await mutate { root in
            guard var servers = root["mcpServers"] as? [String: Any] else { return }
            servers.removeValue(forKey: name)
            root["mcpServers"] = servers
        }
    }

    // MARK: - 공통 mutation pipeline

    /// 임의 mutation closure. 락 + 백업 + atomic rename 보장.
    /// `SettingsWriter.mutate` 와 동일한 invariant 를 다른 파일에 적용.
    private func mutate(_ edit: (inout [String: Any]) throws -> Void) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw WriterError.fileMissing(fileURL)
        }
        try await lock.acquire()
        do {
            try performMutation(edit)
            await lock.release()
        } catch {
            await lock.release()
            throw error
        }
    }

    private func performMutation(_ edit: (inout [String: Any]) throws -> Void) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            throw WriterError.fileMissing(fileURL)
        }

        let data = try Data(contentsOf: fileURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriterError.parseFailed(fileURL, message: "최상위가 객체가 아님")
        }

        try backup.snapshot(fileURL)

        try edit(&root)

        let updated: Data
        do {
            updated = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw WriterError.writeFailed(fileURL, message: "JSON 직렬화 실패: \(error)")
        }

        let tmp = fileURL.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try updated.write(to: tmp)
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw WriterError.writeFailed(fileURL, message: "atomic rename 실패: \(error)")
        }
    }
}
