import Testing
import Foundation
@testable import PluginCore

@Suite("InstalledReader — 본인 환경")
struct InstalledReaderTests {

    @Test("실제 ~/.claude 의 installed_plugins.json 로딩")
    func loadsRealFile() async throws {
        let reader = InstalledReader()
        let file = try await reader.load()
        #expect(file.version == 2)
        #expect(!file.plugins.isEmpty)
    }

    @Test("존재하지 않는 파일은 fileNotFound throw")
    func nonExistentFile_throws() async {
        let reader = InstalledReader(fileURL: URL(fileURLWithPath: "/no/such/installed.json"))
        await #expect(throws: InstalledReader.ReaderError.self) {
            _ = try await reader.load()
        }
    }

    @Test("Fixture 로드 (격리 환경)")
    func fixtureLoads() async throws {
        let fixtureURL = try fixtureURL("installed_plugins_real.json")
        let reader = InstalledReader(fileURL: fixtureURL)
        let file = try await reader.load()
        #expect(file.plugins.count == 26)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "fixture missing: \(name)"])
        }
        return url
    }
}

@Suite("MarketplaceReader — 본인 환경")
struct MarketplaceReaderTests {

    @Test("실제 ~/.claude 의 known_marketplaces.json 로딩")
    func loadsKnown() async throws {
        let reader = MarketplaceReader()
        let known = try await reader.loadKnown()
        #expect(known.count >= 6)
        #expect(known["claude-plugins-official"] != nil)
    }

    @Test("실제 marketplace.json catalog 로딩 (claude-plugins-official)")
    func loadsCatalog() async throws {
        let reader = MarketplaceReader()
        let known = try await reader.loadKnown()
        guard let entry = known["claude-plugins-official"] else {
            Issue.record("claude-plugins-official 마켓 미발견"); return
        }
        let catalog = try await reader.loadCatalog(
            at: URL(fileURLWithPath: entry.installLocation)
        )
        #expect(catalog.name == "claude-plugins-official")
        #expect(catalog.plugins.count >= 100, "공식 마켓은 100+ 플러그인")
        // 알려진 플러그인 존재 검증
        #expect(catalog.plugins.contains { $0.name == "feature-dev" })
    }

    @Test("loadAllCatalogs — 모든 마켓 로드 + 에러 누적")
    func loadsAllCatalogs() async throws {
        let reader = MarketplaceReader()
        let result = try await reader.loadAllCatalogs()
        #expect(result.catalogs.count >= 6)
        // 본인 환경에선 모든 마켓이 로드되어야 정상 — 에러는 0개 기대
        if !result.errors.isEmpty {
            Issue.record("일부 마켓 catalog 로드 실패: \(result.errors.keys)")
        }
    }
}

@Suite("SettingsReader — 본인 환경")
struct SettingsReaderTests {

    @Test("실제 settings.json 의 enabledPlugins / extraKnownMarketplaces 로딩")
    func loadsRealSettings() async throws {
        let reader = SettingsReader()
        let settings = try await reader.load()
        let enabled = settings.enabledPlugins ?? [:]
        #expect(!enabled.isEmpty, "enabledPlugins 비어있음 — 본인 환경 가정")
        let markets = settings.extraKnownMarketplaces ?? [:]
        #expect(markets["claude-plugins-official"] != nil)
    }

    @Test("존재하지 않는 settings.json 은 fileNotFound throw")
    func nonExistentFile_throws() async {
        let reader = SettingsReader(fileURL: URL(fileURLWithPath: "/no/such/settings.json"))
        await #expect(throws: SettingsReader.ReaderError.self) {
            _ = try await reader.load()
        }
    }

    @Test("빈 객체 `{}` 도 정상 디코드 — 모든 키 nil")
    func emptyObject_decodes() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "settings-empty-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reader = SettingsReader(fileURL: tmp)
        let settings = try await reader.load()
        #expect(settings.enabledPlugins == nil)
        #expect(settings.extraKnownMarketplaces == nil)
    }

    @Test("미지원 키는 무시 — passthrough 의도 확인")
    func unknownKeys_ignored() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "settings-extra-\(UUID().uuidString).json")
        let json = """
        {
          "enabledPlugins": {"foo@bar": true},
          "statusLine": {"type": "command", "command": "echo hi"},
          "permissions": {"allow": ["Bash"]}
        }
        """
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reader = SettingsReader(fileURL: tmp)
        let settings = try await reader.load()
        #expect(settings.enabledPlugins?["foo@bar"] == true)
        // statusLine / permissions 는 type 에 없음 → 무시되며 throw 없음.
    }
}

@Suite("PluginManifestReader")
struct PluginManifestReaderTests {

    @Test("실제 cache 의 plugin.json 디코드 — 임의 1개 선택")
    func decodesRealManifest() async throws {
        let manifestURL = try findFirstManifest(under: ClaudePaths.cacheDir)
        let installPath = manifestURL
            .deletingLastPathComponent()  // .claude-plugin/
            .deletingLastPathComponent()  // <version>/
        let reader = PluginManifestReader()
        let manifest = try await reader.loadManifest(at: installPath)
        #expect(!manifest.name.isEmpty)
    }

    @Test("plugin.json 누락 → manifestNotFound throw")
    func missingManifest_throws() async {
        let reader = PluginManifestReader()
        let dummy = URL(fileURLWithPath: "/tmp/cc-pm-no-such-\(UUID().uuidString)")
        await #expect(throws: PluginManifestReader.ReaderError.self) {
            _ = try await reader.loadManifest(at: dummy)
        }
    }

    @Test("PluginAuthor — string / object 두 형식 모두 디코드")
    func authorBothShapes() throws {
        let dec = JSONCoding.decoder()
        let stringForm = try dec.decode(PluginAuthor.self, from: Data("\"Toby Lee\"".utf8))
        #expect(stringForm.name == "Toby Lee")
        #expect(stringForm.email == nil)

        let objectForm = try dec.decode(
            PluginAuthor.self,
            from: Data(#"{"name":"Toby","email":"t@example.com"}"#.utf8)
        )
        #expect(objectForm.name == "Toby")
        #expect(objectForm.email == "t@example.com")
    }

    @Test("countComponents — 디렉토리 + JSON 파일 카운트")
    func countsComponents() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-mreader-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        try fm.createDirectory(at: root.appending(path: "commands"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "commands/a.md"))
        try Data().write(to: root.appending(path: "commands/b.md"))
        try Data().write(to: root.appending(path: "commands/notes.txt"))  // 무시: .md 아님

        try fm.createDirectory(at: root.appending(path: "agents"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "agents/foo.md"))

        try fm.createDirectory(at: root.appending(path: "skills/one"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "skills/one/SKILL.md"))
        try fm.createDirectory(at: root.appending(path: "skills/two"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "skills/two/SKILL.md"))
        try fm.createDirectory(at: root.appending(path: "skills/empty"), withIntermediateDirectories: true)
        // skills/empty 는 SKILL.md 없음 → 무시

        try fm.createDirectory(at: root.appending(path: "hooks"), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"PreToolUse":[{"matcher":"a"},{"matcher":"b"}],"Stop":[{"matcher":"c"}]}}"#.utf8)
            .write(to: root.appending(path: "hooks/hooks.json"))

        try Data(#"{"mcpServers":{"x":{"command":"y"}}}"#.utf8)
            .write(to: root.appending(path: ".mcp.json"))

        let reader = PluginManifestReader()
        let counts = await reader.countComponents(at: root)
        #expect(counts.commands == 2)
        #expect(counts.agents == 1)
        #expect(counts.skills == 2)
        #expect(counts.hooks == 3)
        #expect(counts.mcpServers == 1)
        #expect(counts.lspServers == 0)
    }

    @Test("countComponents — 모든 디렉토리 누락 시 zero")
    func countsZeroOnMissing() async throws {
        let dummy = URL(fileURLWithPath: "/tmp/cc-pm-missing-\(UUID().uuidString)")
        let reader = PluginManifestReader()
        let counts = await reader.countComponents(at: dummy)
        #expect(counts == .zero)
    }

    private func findFirstManifest(under dir: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            throw NSError(
                domain: "Test", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "cache 디렉토리 enumerate 실패: \(dir.path)"]
            )
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "plugin.json",
               url.deletingLastPathComponent().lastPathComponent == ".claude-plugin" {
                return url
            }
        }
        throw NSError(
            domain: "Test", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "plugin.json 미발견 in \(dir.path)"]
        )
    }
}

@Suite("FSEventsWatcher — 실제 파일시스템 변경 감지")
struct FSEventsWatcherTests {

    @Test("디렉토리 변경 감지 callback fires", .timeLimit(.minutes(1)))
    func detectsFileCreation() async throws {
        let tmpDir = URL(fileURLWithPath: "/tmp/cc-pm-fsevents-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()  // /tmp → /private/tmp 정규화
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let detected = AsyncStream<Set<URL>>.makeStream()
        let watcher = FSEventsWatcher(paths: [tmpDir], latency: 0.2, ignoreSelf: false)
        watcher.start { urls in
            detected.continuation.yield(urls)
        }
        defer {
            watcher.stop()
            detected.continuation.finish()
        }

        try await Task.sleep(for: .milliseconds(300))  // FSEvents 시작 대기

        let target = tmpDir.appending(path: "test.txt")
        try "hello".write(to: target, atomically: true, encoding: .utf8)

        // 변경된 파일 경로 또는 부모 디렉토리가 reported event 에 포함되는지 확인.
        // FSEvents 는 여러 batch 로 나눠 보고할 수 있으므로 첫 batch 에 못 받을 수 있음.
        var sawChange = false
        let deadline = ContinuousClock.now + .seconds(3)
        for await urls in detected.stream {
            let pathSet = Set(urls.map { $0.resolvingSymlinksInPath().path })
            if pathSet.contains(target.path) || pathSet.contains(tmpDir.path) {
                sawChange = true
                break
            }
            if ContinuousClock.now > deadline { break }
        }
        #expect(sawChange, "FSEvents 가 \(target.path) 또는 \(tmpDir.path) 변경을 보고해야 함")
    }

    @Test("stop() 후엔 callback 안 옴")
    func stopHaltsCallback() async throws {
        let tmpDir = URL(fileURLWithPath: "/tmp/cc-pm-fsevents-stop-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let counter = CallCounter()
        let watcher = FSEventsWatcher(paths: [tmpDir], latency: 0.1, ignoreSelf: false)
        watcher.start { _ in counter.increment() }

        try await Task.sleep(for: .milliseconds(300))  // FSEvents 시작 + initial events 흡수
        let countBefore = counter.value
        watcher.stop()

        // stop 후 변경 — 추가 callback 이 발생하면 안 됨
        try "after-stop".write(to: tmpDir.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))

        let countAfter = counter.value
        #expect(countAfter == countBefore,
               "stop() 후엔 카운트 증가 0 기대 — before=\(countBefore), after=\(countAfter)")
    }
}

/// async context 에서 안전한 카운터.
/// `NSLock.lock()` 은 Swift 6 strict concurrency 에서 async 컨텍스트 호출 차단됨 →
/// `withLock` scoped API 사용.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
