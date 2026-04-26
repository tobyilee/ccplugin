import Testing
import Foundation
@testable import PluginCore

@Suite("MarketplaceSource discriminated union")
struct MarketplaceSourceTests {

    @Test("git source 라운드트립 (실측 fixture 형식)")
    func git_roundtrip() throws {
        let json = """
        {
          "source": "git",
          "url": "https://github.com/anthropics/claude-plugins-official.git"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .git(let url, let ref, let path, let sparse) = decoded else {
            Issue.record("git case 기대"); return
        }
        #expect(url == "https://github.com/anthropics/claude-plugins-official.git")
        #expect(ref == nil)
        #expect(path == nil)
        #expect(sparse == nil)
    }

    @Test("github source 라운드트립 (실측 fixture 형식)")
    func github_roundtrip() throws {
        let json = """
        { "source": "github", "repo": "openai/codex-plugin-cc" }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .github(let repo, _, _, _) = decoded else {
            Issue.record("github case 기대"); return
        }
        #expect(repo == "openai/codex-plugin-cc")
    }

    @Test("github with ref/path/sparsePaths 라운드트립")
    func github_full() throws {
        let json = """
        {
          "source": "github",
          "repo": "owner/repo",
          "ref": "main",
          "path": "subdir",
          "sparsePaths": [".claude-plugin", "plugins"]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .github(let repo, let ref, let path, let sparse) = decoded else {
            Issue.record("github case 기대"); return
        }
        #expect(repo == "owner/repo")
        #expect(ref == "main")
        #expect(path == "subdir")
        #expect(sparse == [".claude-plugin", "plugins"])
    }

    @Test("url with headers 라운드트립")
    func url_with_headers() throws {
        let json = """
        {
          "source": "url",
          "url": "https://example.invalid/marketplace.json",
          "headers": { "Authorization": "Bearer xxx" }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .url(let url, let headers) = decoded else {
            Issue.record("url case 기대"); return
        }
        #expect(url == "https://example.invalid/marketplace.json")
        #expect(headers?["Authorization"] == "Bearer xxx")
    }

    @Test("directory source (M0 spike Q2 에서 실측)")
    func directory_source() throws {
        let json = """
        { "source": "directory", "path": "/tmp/cc-pm-spike/test-market" }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .directory(let path) = decoded else {
            Issue.record("directory case 기대"); return
        }
        #expect(path == "/tmp/cc-pm-spike/test-market")
    }

    @Test("file source")
    func file_source() throws {
        let json = #"{ "source": "file", "path": "/local/marketplace.json" }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .file(let path) = decoded else {
            Issue.record("file case 기대"); return
        }
        #expect(path == "/local/marketplace.json")
    }

    @Test("npm source")
    func npm_source() throws {
        let json = #"{ "source": "npm", "package": "@scope/marketplace-pkg" }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .npm(let package) = decoded else {
            Issue.record("npm case 기대"); return
        }
        #expect(package == "@scope/marketplace-pkg")
    }

    @Test("hostPattern source (정책용)")
    func hostPattern_source() throws {
        let json = #"{ "source": "hostPattern", "hostPattern": "^github.com/anthropics/.*$" }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MarketplaceSource.self, from: json)
        guard case .hostPattern(let pattern) = decoded else {
            Issue.record("hostPattern case 기대"); return
        }
        #expect(pattern == "^github.com/anthropics/.*$")
    }

    @Test("알 수 없는 source type 거절")
    func unknown_source_type() {
        let json = #"{ "source": "ftp", "url": "ftp://..." }"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MarketplaceSource.self, from: json)
        }
    }

    @Test("encode → decode 라운드트립 (모든 case)")
    func encode_decode_roundtrip() throws {
        let cases: [MarketplaceSource] = [
            .git(url: "https://x.com/r.git", ref: "main", path: nil, sparsePaths: nil),
            .github(repo: "a/b", ref: nil, path: nil, sparsePaths: nil),
            .url(url: "https://m.json", headers: ["X": "y"]),
            .npm(package: "pkg"),
            .file(path: "/p"),
            .directory(path: "/d"),
            .hostPattern("^x$"),
            .pathPattern("^/api/.*$")
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in cases {
            let data = try encoder.encode(original)
            let roundtripped = try decoder.decode(MarketplaceSource.self, from: data)
            #expect(roundtripped == original, "case mismatch: \(original)")
        }
    }
}

@Suite("KnownMarketplacesFile real fixture")
struct KnownMarketplacesFileTests {

    @Test("실측 6개 마켓 라운드트립")
    func real_6_marketplaces_roundtrip() throws {
        let data = try loadKnownMarketplacesFixture()
        let parsed = try KnownMarketplaceEntry.decodeFile(from: data)

        #expect(parsed.count == 6, "spike 시점 6개 마켓 기대")

        let officialEntry = parsed["claude-plugins-official"]
        #expect(officialEntry != nil)
        if case .git(let url, _, _, _) = officialEntry?.source {
            #expect(url == "https://github.com/anthropics/claude-plugins-official.git")
        } else {
            Issue.record("claude-plugins-official 은 git source 기대")
        }
        #expect(officialEntry?.installLocation.hasSuffix("claude-plugins-official") == true)

        let codex = parsed["openai-codex"]
        if case .github(let repo, _, _, _) = codex?.source {
            #expect(repo == "openai/codex-plugin-cc")
        } else {
            Issue.record("openai-codex 는 github source 기대")
        }
    }

    @Test("autoUpdate 가 true 인 마켓 식별 (실측 3개)")
    func autoUpdate_distribution() throws {
        let data = try loadKnownMarketplacesFixture()
        let parsed = try KnownMarketplaceEntry.decodeFile(from: data)

        let autoUpdateOn = parsed.filter { $0.value.autoUpdate == true }.keys.sorted()
        #expect(autoUpdateOn == ["harness-marketplace", "ralph-marketplace", "toby-plugins"])
    }

    @Test("encode 라운드트립 의미적 동등성")
    func encode_roundtrip() throws {
        let original = try loadKnownMarketplacesFixture()
        let parsed = try KnownMarketplaceEntry.decodeFile(from: original)
        let reEncoded = try KnownMarketplaceEntry.encodeFile(parsed)

        let originalNorm = try JSONSerialization.jsonObject(with: original)
        let reEncodedNorm = try JSONSerialization.jsonObject(with: reEncoded)
        #expect(JSONTestHelpers.equalIgnoringFormatting(originalNorm, reEncodedNorm))
    }

    private func loadKnownMarketplacesFixture() throws -> Data {
        try loadFixture("known_marketplaces_real.json")
    }
}
