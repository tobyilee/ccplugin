import Testing
import Foundation
@testable import PluginCore

@Suite("HookMatcher — string-or-object 디코드")
struct HookMatcherTests {

    @Test("문자열 형식 → .literal")
    func literalString() throws {
        let dec = JSONCoding.decoder()
        let m = try dec.decode(HookMatcher.self, from: Data("\"Bash\"".utf8))
        #expect(m == .literal("Bash"))
        #expect(m.displayText == "Bash")
    }

    @Test("객체 형식 (pattern) → .regex")
    func regexObject() throws {
        let dec = JSONCoding.decoder()
        let m = try dec.decode(
            HookMatcher.self,
            from: Data(#"{"type":"regex","pattern":"^foo"}"#.utf8)
        )
        #expect(m == .regex(pattern: "^foo"))
        #expect(m.displayText.contains("^foo"))
    }

    @Test("알 수 없는 형식 → .unknown (decode 성공)")
    func unknownObject() throws {
        let dec = JSONCoding.decoder()
        let m = try dec.decode(HookMatcher.self, from: Data(#"{"weird":42}"#.utf8))
        #expect(m == .unknown)
    }
}

@Suite("ManagerSettingsSubset — hooks 필드")
struct ManagerSettingsHooksTests {

    @Test("hooks 블록 디코드 — 다양한 매처 형식")
    func decodeHooks() throws {
        let json = #"""
        {
          "enabledPlugins": {"a@b": true},
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": "echo hi", "timeout": 30}]
              },
              {
                "matcher": {"type": "regex", "pattern": "^foo"},
                "hooks": [{"type": "command", "command": "true"}]
              }
            ]
          }
        }
        """#
        let s = try JSONCoding.decoder().decode(
            ManagerSettingsSubset.self,
            from: Data(json.utf8)
        )
        #expect(s.enabledPlugins?["a@b"] == true)
        let pre = s.hooks?["PreToolUse"]
        #expect(pre?.count == 2)
        #expect(pre?[0].matcher == .literal("Bash"))
        #expect(pre?[0].hooks.first?.command == "echo hi")
        #expect(pre?[0].hooks.first?.timeout == 30)
        #expect(pre?[1].matcher == .regex(pattern: "^foo"))
        #expect(pre?[1].hooks.first?.timeout == nil)
    }

    @Test("hooks 미존재 시 nil 정상")
    func hooksAbsent() throws {
        let s = try JSONCoding.decoder().decode(
            ManagerSettingsSubset.self,
            from: Data(#"{"enabledPlugins":{}}"#.utf8)
        )
        #expect(s.hooks == nil)
    }

    /// 회귀: matcher 없는 hooks entry 가 전체 디코딩을 죽이면 안 됨.
    /// SessionStart/Stop/UserPromptSubmit 같은 이벤트는 matcher 가 의미 없어 보통 생략됨.
    /// 이 케이스에서 디코딩이 실패하면 enabledPlugins 가 빈값으로 떨어져
    /// Installed 탭이 모두 disabled 로 나오고 토글이 작동하지 않음.
    @Test("matcher 없는 hooks entry 도 디코드 — enabledPlugins 보존")
    func matcherlessHookDoesNotBreakSettings() throws {
        let json = #"""
        {
          "enabledPlugins": {"plugin-a@market": true, "plugin-b@market": false},
          "hooks": {
            "SessionStart": [
              {
                "hooks": [{"type": "command", "command": "/bin/true"}]
              }
            ]
          }
        }
        """#
        let s = try JSONCoding.decoder().decode(
            ManagerSettingsSubset.self,
            from: Data(json.utf8)
        )
        #expect(s.enabledPlugins?["plugin-a@market"] == true)
        #expect(s.enabledPlugins?["plugin-b@market"] == false)
        let entry = s.hooks?["SessionStart"]?.first
        #expect(entry?.matcher == nil)
        #expect(entry?.hooks.first?.command == "/bin/true")
    }
}

@Suite("SettingsWriter — hooks add/remove")
struct SettingsWriterHooksTests {

    @Test("addHook — 빈 hooks 에 새 이벤트 + 엔트리 추가")
    func addHook_toEmpty() async throws {
        let (file, backupDir) = freshSettings(#"{}"#)
        defer { cleanup(file) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.addHook(
            event: "PreToolUse",
            matcher: "Bash",
            command: "echo hello",
            timeout: 30
        )

        let obj = try parse(file)
        let hooks = obj?["hooks"] as? [String: Any]
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 1)
        #expect(pre?.first?["matcher"] as? String == "Bash")
        let cmds = pre?.first?["hooks"] as? [[String: Any]]
        #expect(cmds?.first?["command"] as? String == "echo hello")
        #expect(cmds?.first?["timeout"] as? Int == 30)
    }

    @Test("addHook — 기존 이벤트에 append")
    func addHook_appends() async throws {
        let (file, backupDir) = freshSettings(#"""
        {
          "hooks": {
            "PreToolUse": [
              {"matcher": "Existing", "hooks": [{"type": "command", "command": "x"}]}
            ]
          }
        }
        """#)
        defer { cleanup(file) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.addHook(event: "PreToolUse", matcher: "New", command: "y")

        let obj = try parse(file)
        let pre = (obj?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 2)
        #expect(pre?[0]["matcher"] as? String == "Existing")
        #expect(pre?[1]["matcher"] as? String == "New")
    }

    @Test("removeHook — index 로 제거 + 마지막 제거 시 event 키 사라짐")
    func removeHook_lastEntryRemovesEvent() async throws {
        let (file, backupDir) = freshSettings(#"""
        {
          "hooks": {
            "Stop": [
              {"matcher": "X", "hooks": [{"type": "command", "command": "a"}]}
            ]
          }
        }
        """#)
        defer { cleanup(file) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.removeHook(event: "Stop", at: 0)

        let obj = try parse(file)
        let hooks = obj?["hooks"] as? [String: Any]
        #expect(hooks?["Stop"] == nil)
    }

    @Test("removeHook — 범위 밖 index 는 no-op")
    func removeHook_outOfRange_noop() async throws {
        let (file, backupDir) = freshSettings(#"""
        {
          "hooks": {
            "Stop": [
              {"matcher": "X", "hooks": [{"type": "command", "command": "a"}]}
            ]
          }
        }
        """#)
        defer { cleanup(file) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.removeHook(event: "Stop", at: 99)

        let obj = try parse(file)
        let stop = (obj?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
    }

    private func freshSettings(_ json: String) -> (URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-hk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "settings.json", directoryHint: .notDirectory)
        let backupDir = dir.appending(path: "backups", directoryHint: .isDirectory)
        try? Data(json.utf8).write(to: file)
        return (file, backupDir)
    }

    private func cleanup(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func parse(_ file: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: file)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@Suite("UserAssetReader — 격리 환경 + 본인 환경")
struct UserAssetReaderTests {

    @Test("격리 fixture 디렉토리 — skill/agent/command 모두 카운트")
    func fixtureScan() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-ua-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        // skills: 2 valid + 1 missing SKILL.md
        try fm.createDirectory(at: dir.appending(path: "skills/alpha"), withIntermediateDirectories: true)
        try Data("# alpha".utf8).write(to: dir.appending(path: "skills/alpha/SKILL.md"))
        try fm.createDirectory(at: dir.appending(path: "skills/beta"), withIntermediateDirectories: true)
        try Data("# beta".utf8).write(to: dir.appending(path: "skills/beta/SKILL.md"))
        try fm.createDirectory(at: dir.appending(path: "skills/empty"), withIntermediateDirectories: true)

        // agents: 2 .md + 1 .txt
        try fm.createDirectory(at: dir.appending(path: "agents"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "agents/foo.md"))
        try Data().write(to: dir.appending(path: "agents/bar.md"))
        try Data().write(to: dir.appending(path: "agents/notes.txt"))

        // commands: 1 .md
        try fm.createDirectory(at: dir.appending(path: "commands"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "commands/qux.md"))

        let reader = UserAssetReader(configDir: dir)
        let assets = await reader.loadAll()

        let skills = assets.filter { $0.kind == .skill }
        let agents = assets.filter { $0.kind == .agent }
        let commands = assets.filter { $0.kind == .command }
        #expect(skills.count == 2)
        #expect(agents.count == 2)
        #expect(commands.count == 1)
        #expect(skills.map(\.name).sorted() == ["alpha", "beta"])
    }

    @Test("본인 환경 — skills 디렉토리 존재")
    func realEnvScan() async {
        let reader = UserAssetReader()
        let assets = await reader.loadAll()
        // 결과 0개여도 통과 (사용자 환경 의존). throw 없음만 확인.
        _ = assets
    }
}

@Suite("CacheCleanup")
struct CacheCleanupTests {

    @Test("plan — fixture 환경에서 orphan 식별")
    func planIdentifiesOrphans() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanup = CacheCleanup(
            cacheDir: dir.appending(path: "cache"),
            installedReader: InstalledReader(
                fileURL: dir.appending(path: "installed.json")
            )
        )
        let plan = await cleanup.plan()
        // installed: market1/plug1/1.0 — 나머지 모두 orphan
        let names = plan.orphanedDirs
            .map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" }
            .sorted()
        #expect(names == ["plug1/0.9", "plug2/2.0"])
    }

    @Test("execute — orphan 제거 + installed 보존")
    func executeRemovesOrphans() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanup = CacheCleanup(
            cacheDir: dir.appending(path: "cache"),
            installedReader: InstalledReader(
                fileURL: dir.appending(path: "installed.json")
            )
        )
        let result = await cleanup.execute()
        #expect(result.removed.count == 2)
        #expect(result.failed.isEmpty)

        let fm = FileManager.default
        // installed 디렉토리는 살아있어야 함
        #expect(fm.fileExists(atPath: dir.appending(path: "cache/market1/plug1/1.0").path))
        // 두 orphan 은 제거되어야 함
        #expect(!fm.fileExists(atPath: dir.appending(path: "cache/market1/plug1/0.9").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "cache/market1/plug2/2.0").path))
    }

    /// installed entry 1개 + orphan 디렉토리 2개를 포함한 fixture 생성.
    private func makeFixture() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let cache = dir.appending(path: "cache")
        let installed = cache
            .appending(path: "market1/plug1/1.0", directoryHint: .isDirectory)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        // orphans
        try fm.createDirectory(
            at: cache.appending(path: "market1/plug1/0.9"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: cache.appending(path: "market1/plug2/2.0"),
            withIntermediateDirectories: true
        )

        // installed_plugins.json: V2 형식, 위 1.0 만 등록.
        let installedJSON = #"""
        {
          "version": 2,
          "plugins": {
            "plug1@market1": [
              {
                "scope": "user",
                "installPath": "\#(installed.path)",
                "version": "1.0"
              }
            ]
          }
        }
        """#
        try Data(installedJSON.utf8).write(
            to: dir.appending(path: "installed.json", directoryHint: .notDirectory)
        )
        return dir
    }
}

@Suite("DiagnosticsRunner — 본인 환경")
struct DiagnosticsRunnerTests {

    @Test("runAll 실행 — 본인 환경에서 throw 없이 진단 리스트 반환")
    func runAll_noThrow() async {
        let runner = DiagnosticsRunner()
        let diags = await runner.runAll()
        // 진단 0~N 개 — 환경 의존. 정렬만 검증.
        let severityOrder: [DiagnosticsRunner.Diagnostic.Severity] = [.error, .warning, .info]
        let firstSeverity = diags.first?.severity ?? .info
        let lastSeverity = diags.last?.severity ?? .info
        if let firstIdx = severityOrder.firstIndex(of: firstSeverity),
           let lastIdx = severityOrder.firstIndex(of: lastSeverity) {
            #expect(firstIdx <= lastIdx, "심각도 정렬: error → warning → info")
        }
    }
}
