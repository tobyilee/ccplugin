import Testing
import Foundation
@testable import PluginCore

@Suite("MCPReader — user + plugin source 합산")
struct MCPReaderTests {

    @Test("user-scope MCP 만 있을 때 — 이름/command/사용자 source 채움")
    func userOnly() async throws {
        let dir = tmpDir()
        defer { cleanup(dir) }
        let claudeJSON = dir.appending(path: ".claude.json", directoryHint: .notDirectory)
        try Data(#"""
        {
          "mcpServers": {
            "alpha": {"command": "/bin/alpha", "args": ["--flag"]},
            "beta":  {"command": "/bin/beta"}
          },
          "projects": {}
        }
        """#.utf8).write(to: claudeJSON)

        let reader = MCPReader()
        let mcps = await reader.readAll(plugins: [], claudeJSONPath: claudeJSON)
        #expect(mcps.count == 2)
        let alpha = try #require(mcps.first { $0.name == "alpha" })
        if case .user = alpha.source { } else { Issue.record("alpha must be user-scope") }
        #expect(alpha.command == "/bin/alpha")
        #expect(alpha.args == ["--flag"])
        #expect(alpha.isEnabledEverywhere == true)
    }

    @Test("plugin .mcp.json 만 있을 때 — plugin source 채움")
    func pluginOnly() async throws {
        let dir = tmpDir()
        defer { cleanup(dir) }
        let claudeJSON = dir.appending(path: ".claude.json", directoryHint: .notDirectory)
        try Data(#"{"mcpServers":{}, "projects":{}}"#.utf8).write(to: claudeJSON)

        let pluginPath = dir.appending(path: "plugins/foo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pluginPath, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"x":{"command":"y"}}}"#.utf8)
            .write(to: pluginPath.appending(path: ".mcp.json", directoryHint: .notDirectory))

        let reader = MCPReader()
        let mcps = await reader.readAll(
            plugins: [(id: "foo@market", installPath: pluginPath)],
            claudeJSONPath: claudeJSON
        )
        #expect(mcps.count == 1)
        let x = mcps[0]
        #expect(x.name == "x")
        if case .plugin(let pluginID, _) = x.source {
            #expect(pluginID == "foo@market")
        } else {
            Issue.record("x must be plugin-source")
        }
    }

    @Test("어떤 프로젝트에서라도 disabled 면 isEnabledEverywhere == false")
    func disabledInAnyProject() async throws {
        let dir = tmpDir()
        defer { cleanup(dir) }
        let claudeJSON = dir.appending(path: ".claude.json", directoryHint: .notDirectory)
        try Data(#"""
        {
          "mcpServers": {"shared": {"command": "/bin/sh"}},
          "projects": {
            "/proj/a": {"disabledMcpServers": ["shared"]},
            "/proj/b": {}
          }
        }
        """#.utf8).write(to: claudeJSON)

        let reader = MCPReader()
        let mcps = await reader.readAll(plugins: [], claudeJSONPath: claudeJSON)
        let shared = try #require(mcps.first { $0.name == "shared" })
        #expect(shared.isEnabledEverywhere == false)
        #expect(shared.disabledInProjects == ["/proj/a"])
    }

    @Test("user 와 plugin 에 같은 이름 — 두 행으로 분리, id 다름")
    func sameNameDifferentSources() async throws {
        let dir = tmpDir()
        defer { cleanup(dir) }
        let claudeJSON = dir.appending(path: ".claude.json", directoryHint: .notDirectory)
        try Data(#"""
        {"mcpServers":{"dup":{"command":"/usr"}}, "projects":{}}
        """#.utf8).write(to: claudeJSON)
        let pluginPath = dir.appending(path: "plugins/p", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pluginPath, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"dup":{"command":"/plug"}}}"#.utf8)
            .write(to: pluginPath.appending(path: ".mcp.json", directoryHint: .notDirectory))

        let reader = MCPReader()
        let mcps = await reader.readAll(
            plugins: [(id: "p@m", installPath: pluginPath)],
            claudeJSONPath: claudeJSON
        )
        #expect(mcps.count == 2)
        #expect(Set(mcps.map(\.id)).count == 2)
    }

    @Test("~/.claude.json 미존재 — 빈 결과")
    func missingClaudeJSON() async {
        let bogus = URL(fileURLWithPath: "/no/such/.claude-\(UUID().uuidString).json")
        let reader = MCPReader()
        let mcps = await reader.readAll(plugins: [], claudeJSONPath: bogus)
        #expect(mcps.isEmpty)
    }

    private func tmpDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-mcp-r-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite("ClaudeJSONWriter — disable / enable / remove with passthrough")
struct ClaudeJSONWriterTests {

    @Test("setMCPEnabledEverywhere(.user, false) — 모든 프로젝트의 disabledMcpServers 에 추가")
    func disableUserScope_addsToEveryProject() async throws {
        let (file, backupDir) = freshClaudeJSON(#"""
        {
          "mcpServers": {"sv": {"command": "/x"}},
          "projects": {
            "/proj/a": {},
            "/proj/b": {"disabledMcpServers": ["other"]}
          },
          "claudeAiMcpEverConnected": true,
          "customField": 42
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }
        let writer = ClaudeJSONWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )

        try await writer.setMCPEnabledEverywhere(name: "sv", source: .user, enabled: false)

        let obj = try readJSON(file)
        let projects = obj["projects"] as? [String: Any]
        let a = projects?["/proj/a"] as? [String: Any]
        let b = projects?["/proj/b"] as? [String: Any]
        let aDisabled = a?["disabledMcpServers"] as? [String]
        let bDisabled = b?["disabledMcpServers"] as? [String]
        #expect(aDisabled?.contains("sv") == true)
        #expect(bDisabled?.contains("sv") == true)
        #expect(bDisabled?.contains("other") == true)  // 기존 항목 보존
        // passthrough invariant
        #expect(obj["claudeAiMcpEverConnected"] as? Bool == true)
        #expect(obj["customField"] as? Int == 42)
    }

    @Test("setMCPEnabledEverywhere(.user, true) — 모든 프로젝트의 disabledMcpServers 에서 제거")
    func enableUserScope_removesFromEveryProject() async throws {
        let (file, backupDir) = freshClaudeJSON(#"""
        {
          "mcpServers": {"sv": {"command": "/x"}},
          "projects": {
            "/proj/a": {"disabledMcpServers": ["sv", "other"]},
            "/proj/b": {"disabledMcpServers": ["sv"]}
          }
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }
        let writer = ClaudeJSONWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )

        try await writer.setMCPEnabledEverywhere(name: "sv", source: .user, enabled: true)

        let obj = try readJSON(file)
        let projects = obj["projects"] as? [String: Any]
        let a = (projects?["/proj/a"] as? [String: Any])?["disabledMcpServers"] as? [String]
        let b = (projects?["/proj/b"] as? [String: Any])?["disabledMcpServers"] as? [String]
        #expect(a?.contains("sv") == false)
        #expect(a?.contains("other") == true)
        #expect(b?.contains("sv") == false)
    }

    @Test("setMCPEnabledEverywhere(.pluginJSON, true) — enabledMcpjsonServers 에 추가, disabledMcpjsonServers 에서 제거")
    func enablePluginScope_movesAcrossLists() async throws {
        let (file, backupDir) = freshClaudeJSON(#"""
        {
          "projects": {
            "/proj": {
              "disabledMcpjsonServers": ["bundled"],
              "enabledMcpjsonServers": []
            }
          }
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }
        let writer = ClaudeJSONWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )

        try await writer.setMCPEnabledEverywhere(name: "bundled", source: .pluginJSON, enabled: true)

        let obj = try readJSON(file)
        let p = (obj["projects"] as? [String: Any])?["/proj"] as? [String: Any]
        let disabled = p?["disabledMcpjsonServers"] as? [String]
        let enabled = p?["enabledMcpjsonServers"] as? [String]
        #expect(disabled?.contains("bundled") == false)
        #expect(enabled?.contains("bundled") == true)
    }

    @Test("removeUserScopeMCP — mcpServers 의 키만 제거, 다른 항목 보존")
    func removeUserScope_dropsOnlyOne() async throws {
        let (file, backupDir) = freshClaudeJSON(#"""
        {
          "mcpServers": {
            "a": {"command": "/a"},
            "b": {"command": "/b"},
            "c": {"command": "/c"}
          },
          "projects": {}
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }
        let writer = ClaudeJSONWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )

        try await writer.removeUserScopeMCP(name: "b")

        let obj = try readJSON(file)
        let servers = obj["mcpServers"] as? [String: Any]
        #expect(servers?.count == 2)
        #expect(servers?["a"] != nil)
        #expect(servers?["c"] != nil)
        #expect(servers?["b"] == nil)
    }

    @Test("disable 후 enable 라운드트립 — 모든 알려지지 않은 키 보존")
    func disableEnableRoundtrip_preservesUnknownKeys() async throws {
        let (file, backupDir) = freshClaudeJSON(#"""
        {
          "mcpServers": {"sv": {"command": "/x"}},
          "projects": {
            "/proj": {"customProjField": "keep me"}
          },
          "topLevelExtra": [1, 2, 3]
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }
        let writer = ClaudeJSONWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )

        try await writer.setMCPEnabledEverywhere(name: "sv", source: .user, enabled: false)
        try await writer.setMCPEnabledEverywhere(name: "sv", source: .user, enabled: true)

        let obj = try readJSON(file)
        let projects = obj["projects"] as? [String: Any]
        let p = projects?["/proj"] as? [String: Any]
        #expect(p?["customProjField"] as? String == "keep me")
        let arr = obj["topLevelExtra"] as? [Int]
        #expect(arr == [1, 2, 3])
    }

    @Test("~/.claude.json 미존재 → fileMissing throw")
    func missingFile_throws() async {
        let bogus = URL(fileURLWithPath: "/no/such/.claude-\(UUID().uuidString).json")
        let writer = ClaudeJSONWriter(
            fileURL: bogus,
            backup: BackupService(backupDir: bogus.deletingLastPathComponent(), limit: 5)
        )
        await #expect(throws: ClaudeJSONWriter.WriterError.self) {
            try await writer.removeUserScopeMCP(name: "anything")
        }
    }

    // Helpers
    private func freshClaudeJSON(_ json: String) -> (URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-cjw-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: ".claude.json", directoryHint: .notDirectory)
        let backupDir = dir.appending(path: "backups", directoryHint: .isDirectory)
        try? Data(json.utf8).write(to: file)
        return (file, backupDir)
    }

    private func cleanup(_ file: URL, backupDir: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
