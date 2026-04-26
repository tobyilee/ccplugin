import Testing
import Foundation
@testable import PluginCore

/// PRD §11.1 — Golden fixture roundtrip test.
/// 본인 환경의 `~/.claude/plugins/installed_plugins.json` 을 fixture 로 commit
/// → 디코드 + 재인코드 라운드트립 시 semantic 동등성 (key 순서/공백 무시) 검증.
///
/// Xcode 없이도 동작하도록 `swift-testing` 사용 (Swift 6+).
@Suite("InstalledPluginsFileV2 Schema")
struct InstalledPluginsV2Tests {

    @Test("real fixture (26 plugins) decodes")
    func decodesRealFixture() throws {
        let data = try loadFixture("installed_plugins_real.json")
        let parsed = try InstalledPluginsFileV2.decode(from: data)

        #expect(parsed.version == 2)
        #expect(parsed.plugins.count == 26, "Spike 시점 26개 기대")

        let codex = parsed.plugins["codex@openai-codex"]
        #expect(codex != nil)
        #expect(codex?.first?.scope == .user)
        #expect(codex?.first?.version == "1.0.2")

        for (id, entries) in parsed.plugins {
            #expect(!entries.isEmpty, "id=\(id) 의 installations 배열 비면 안 됨")
            for entry in entries {
                #expect(!entry.installPath.isEmpty, "installPath 필수")
            }
        }
    }

    @Test("roundtrip preserves semantics (key/공백 무시)")
    func roundtripPreservesSemantics() throws {
        let original = try loadFixture("installed_plugins_real.json")
        let parsed = try InstalledPluginsFileV2.decode(from: original)
        let reEncoded = try InstalledPluginsFileV2.encode(parsed)

        let originalNorm = try JSONSerialization.jsonObject(with: original)
        let reEncodedNorm = try JSONSerialization.jsonObject(with: reEncoded)

        #expect(
            JSONTestHelpers.equalIgnoringFormatting(originalNorm, reEncodedNorm),
            "라운드트립 후 의미적으로 다름 — key 누락/형식 변환 손실"
        )
    }

    @Test("V3 schema 는 read-only mode 진입 위해 throw")
    func rejectsUnknownVersion() {
        let v3 = """
        { "version": 3, "plugins": {} }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try InstalledPluginsFileV2.decode(from: v3)
        }
    }

    @Test("directory source 는 gitCommitSha nil 정상 처리 (Q10)")
    func directorySource_handlesMissingGitCommitSha() throws {
        let json = """
        {
          "version": 2,
          "plugins": {
            "spike-dummy@cc-pm-spike-test": [
              {
                "scope": "user",
                "installPath": "/tmp/cache/spike",
                "version": "0.0.1",
                "installedAt": "2026-04-26T01:43:36.617Z",
                "lastUpdated": "2026-04-26T01:43:36.617Z"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let parsed = try InstalledPluginsFileV2.decode(from: json)
        let entry = parsed.plugins["spike-dummy@cc-pm-spike-test"]?.first
        #expect(entry != nil)
        #expect(entry?.gitCommitSha == nil, "directory source 는 gitCommitSha nil 이 정상")
        #expect(entry?.version == "0.0.1")
    }
}

@Suite("PluginID validation")
struct PluginIDTests {

    @Test("canonical IDs 통과", arguments: [
        "feature-dev@claude-plugins-official",
        "oh-my-claudecode@omc",
        "codex@openai-codex",
        "a@b",
        "a-b.c_d@x-y.z_0"
    ])
    func validatesCanonicalIDs(_ id: String) {
        #expect(PluginID.isValid(id))
    }

    @Test("invalid IDs 거절", arguments: [
        "",
        "noatsign",
        "@only-market",
        "only-name@",
        "-leading-dash@market",
        "plugin@-leading-dash",
        "plugin@market@extra",
        "plugin with space@market"
    ])
    func rejectsInvalidIDs(_ id: String) {
        #expect(!PluginID.isValid(id))
    }

    @Test("parse + build 라운드트립")
    func parseAndBuildRoundtrip() {
        let parsed = PluginID.parse("feature-dev@claude-plugins-official")
        #expect(parsed.name == "feature-dev")
        #expect(parsed.marketplace == "claude-plugins-official")

        let rebuilt = PluginID.build(name: parsed.name, marketplace: parsed.marketplace ?? "")
        #expect(rebuilt == "feature-dev@claude-plugins-official")
    }

    @Test("@ 없는 문자열은 marketplace nil")
    func parseHandlesNoMarketplace() {
        let parsed = PluginID.parse("loose-id")
        #expect(parsed.name == "loose-id")
        #expect(parsed.marketplace == nil)
    }
}

@Suite("PluginScope codable")
struct PluginScopeTests {
    @Test("encode/decode 라운드트립")
    func codable() throws {
        let json = #""user""#.data(using: .utf8)!
        let scope = try JSONDecoder().decode(PluginScope.self, from: json)
        #expect(scope == .user)

        let encoded = try JSONEncoder().encode(PluginScope.managed)
        #expect(String(data: encoded, encoding: .utf8) == #""managed""#)
    }
}

@Suite("ClaudePaths resolution")
struct ClaudePathsTests {
    @Test("CLAUDE_CONFIG_DIR override 또는 ~/.claude")
    func respectsConfigDirOverride() {
        let envOverride = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let configDir = ClaudePaths.configDir
        if let envOverride, !envOverride.isEmpty {
            #expect(configDir.path == (envOverride as NSString).expandingTildeInPath)
        } else {
            #expect(configDir.path.hasSuffix("/.claude"))
        }
        #expect(ClaudePaths.installedPluginsFile.lastPathComponent == "installed_plugins.json")
        #expect(ClaudePaths.knownMarketplacesFile.lastPathComponent == "known_marketplaces.json")
        #expect(ClaudePaths.blocklistFile.lastPathComponent == "blocklist.json")
    }
}

// MARK: - Helpers (공유: TestHelpers.swift 의 loadFixture / JSONTestHelpers)
