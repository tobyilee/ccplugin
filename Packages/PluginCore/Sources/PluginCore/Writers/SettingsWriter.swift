import Foundation

/// `settings.json` 의 매니저-소관 필드 mutation.
///
/// 핵심 invariant: **모르는 키 보존** (passthrough).
/// 구현 방식: Codable 우회 + `JSONSerialization` 으로 read-modify-write.
/// `[String: Any]` 트리에서 알려진 키만 편집, 나머지는 그대로 통과.
///
/// 동시성: `FileLock` 으로 Claude Code 세션과의 race 방지 (PRD §10.4).
/// 안전성: mutation 직전 `BackupService.snapshot` 호출.
/// 원자성: temp 파일 → atomic rename (`replaceItemAt`).
public actor SettingsWriter {

    public enum WriterError: Error, Sendable {
        case fileMissing(URL)
        case parseFailed(URL, message: String)
        case writeFailed(URL, message: String)
        case marketplaceNotDeclared(String)
    }

    private let fileURL: URL
    private let lock: FileLock
    private let backup: BackupService

    public init(
        fileURL: URL = ClaudePaths.userSettingsFile,
        backup: BackupService = BackupService()
    ) {
        self.fileURL = fileURL
        self.lock = FileLock(target: fileURL)
        self.backup = backup
    }

    /// `enabledPlugins[id] = enabled` 패치. 키 없으면 신설.
    public func setPluginEnabled(id: String, enabled: Bool) async throws {
        try await mutate { root in
            var ep = (root["enabledPlugins"] as? [String: Any]) ?? [:]
            ep[id] = enabled
            root["enabledPlugins"] = ep
        }
    }

    /// `extraKnownMarketplaces[name].autoUpdate` 토글. 마켓 미선언 시 throw.
    /// CLI 가 이 옵션을 노출하지 않으므로 매니저가 직접 mutation (PRD §F2.5).
    public func setMarketplaceAutoUpdate(name: String, autoUpdate: Bool) async throws {
        try await mutate { root in
            guard var ekm = root["extraKnownMarketplaces"] as? [String: Any],
                  var entry = ekm[name] as? [String: Any] else {
                throw WriterError.marketplaceNotDeclared(name)
            }
            entry["autoUpdate"] = autoUpdate
            ekm[name] = entry
            root["extraKnownMarketplaces"] = ekm
        }
    }

    /// `hooks[event]` 배열에 새 hook 엔트리 append.
    /// PRD §F5 — settings.json hooks block CRUD.
    public func addHook(
        event: String,
        matcher: String,
        command: String,
        timeout: Int? = nil
    ) async throws {
        try await mutate { root in
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            var commandSpec: [String: Any] = [
                "type": "command",
                "command": command,
            ]
            if let timeout = timeout {
                commandSpec["timeout"] = timeout
            }
            let newEntry: [String: Any] = [
                "matcher": matcher,
                "hooks": [commandSpec],
            ]
            entries.append(newEntry)
            hooks[event] = entries
            root["hooks"] = hooks
        }
    }

    /// `hooks[event]` 의 index 번째 엔트리 제거. 범위 밖이면 no-op.
    /// 마지막 엔트리 제거 시 event 키 자체도 제거.
    public func removeHook(event: String, at index: Int) async throws {
        try await mutate { root in
            guard var hooks = root["hooks"] as? [String: Any],
                  var entries = hooks[event] as? [[String: Any]],
                  index >= 0 && index < entries.count else {
                return  // no-op
            }
            entries.remove(at: index)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
            root["hooks"] = hooks
        }
    }

    /// 임의 mutation closure. 락 + 백업 + atomic rename 보장.
    ///
    /// 락 획득 *전* 에 파일 존재 검증 — 파일이 없으면 lock dir 의 parent 도 없어
    /// `createDirectory` 가 영구 실패하며 무의미하게 timeout 까지 spin 하기 때문.
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

        // 백업은 mutation 직전 — read 성공 후, write 실패 가능 시점에.
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

        // 동일 디렉토리에 temp 파일 → atomic rename.
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
