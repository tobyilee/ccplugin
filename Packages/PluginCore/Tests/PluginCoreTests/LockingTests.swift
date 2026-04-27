import Testing
import Foundation
@testable import PluginCore

@Suite("FileLock — proper-lockfile 호환 디렉토리 락")
struct FileLockTests {

    @Test("acquire 성공 시 .lock 디렉토리 생성")
    func acquireCreatesDir() async throws {
        let target = tmpFile()
        defer { cleanup(target) }
        try Data("dummy".utf8).write(to: target)
        let lock = FileLock(target: target)
        try await lock.acquire()
        let lockDir = target.appendingPathExtension("lock")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: lockDir.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
        await lock.release()
    }

    @Test("release 후 .lock 디렉토리 제거")
    func releaseRemovesDir() async throws {
        let target = tmpFile()
        defer { cleanup(target) }
        try Data("dummy".utf8).write(to: target)
        let lock = FileLock(target: target)
        try await lock.acquire()
        await lock.release()
        let lockDir = target.appendingPathExtension("lock")
        #expect(!FileManager.default.fileExists(atPath: lockDir.path))
    }

    @Test("이미 락이 잡혀 있으면 timeout throw")
    func contention_timesOut() async throws {
        let target = tmpFile()
        defer { cleanup(target) }
        try Data("dummy".utf8).write(to: target)
        let first = FileLock(target: target)
        try await first.acquire()
        defer { Task { await first.release() } }

        let second = FileLock(target: target)
        await #expect(throws: FileLock.LockError.self) {
            try await second.acquire(timeout: .milliseconds(150), pollInterval: .milliseconds(20))
        }
    }

    @Test("withLock 은 성공 + 실패 모두 release 보장")
    func withLock_releasesOnSuccessAndFailure() async throws {
        let target = tmpFile()
        defer { cleanup(target) }
        try Data("dummy".utf8).write(to: target)
        let lock = FileLock(target: target)
        let lockDir = target.appendingPathExtension("lock")

        // success path
        let v: Int = try await lock.withLock { 42 }
        #expect(v == 42)
        #expect(!FileManager.default.fileExists(atPath: lockDir.path))

        // failure path
        struct E: Error {}
        await #expect(throws: E.self) {
            try await lock.withLock { throw E() }
        }
        #expect(!FileManager.default.fileExists(atPath: lockDir.path))
    }

    @Test("metadata.json 이 lock 디렉토리에 작성됨")
    func metadataFileWritten() async throws {
        let target = tmpFile()
        defer { cleanup(target) }
        try Data("dummy".utf8).write(to: target)
        let lock = FileLock(target: target)
        try await lock.acquire()
        defer { Task { await lock.release() } }

        let meta = target.appendingPathExtension("lock").appending(path: "metadata.json")
        #expect(FileManager.default.fileExists(atPath: meta.path))
        let data = try Data(contentsOf: meta)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["pid"] != nil)
        #expect(obj?["timestamp"] != nil)
    }

    private func tmpFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-flock-\(UUID().uuidString).json", directoryHint: .notDirectory)
    }

    private func cleanup(_ target: URL) {
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: target.appendingPathExtension("lock"))
    }
}

@Suite("BackupService")
struct BackupServiceTests {

    @Test("snapshot 생성 + 내용 보존")
    func snapshotCreatesCopy() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "settings.json", directoryHint: .notDirectory)
        try Data(#"{"k":1}"#.utf8).write(to: source)

        let backupDir = dir.appending(path: "backups", directoryHint: .isDirectory)
        let svc = BackupService(backupDir: backupDir, limit: 5)
        let backupURL = try svc.snapshot(source)

        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(backupURL.lastPathComponent.contains("settings.json"))
        #expect(backupURL.lastPathComponent.hasSuffix(".bak"))
        let content = try Data(contentsOf: backupURL)
        #expect(String(data: content, encoding: .utf8) == #"{"k":1}"#)
    }

    @Test("source 누락 → sourceMissing throw")
    func missingSource_throws() {
        let svc = BackupService(backupDir: tmpDir(), limit: 5)
        let bogus = URL(fileURLWithPath: "/no/such/source.json")
        #expect(throws: BackupService.BackupError.self) {
            _ = try svc.snapshot(bogus)
        }
    }

    @Test("limit 초과 시 오래된 백업 제거")
    func pruneEnforcesLimit() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "x.json", directoryHint: .notDirectory)
        try Data(#"{}"#.utf8).write(to: source)

        let backupDir = dir.appending(path: "backups", directoryHint: .isDirectory)
        let svc = BackupService(backupDir: backupDir, limit: 3)
        // 5 회 snapshot → 3개만 남아야 함.
        for _ in 0..<5 {
            _ = try svc.snapshot(source)
            // ISO8601-fractional 이라도 동시 호출 시 동일 stamp 가능 → sleep 1ms
            Thread.sleep(forTimeInterval: 0.005)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil
        )
        #expect(entries.count == 3)
    }

    private func tmpDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-bck-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("SettingsWriter — passthrough mutation")
struct SettingsWriterTests {

    @Test("setPluginEnabled — 새 키 추가, 기존 모든 키 보존")
    func enablePlugin_preservesUnknownKeys() async throws {
        let (file, backupDir) = freshSettings(#"""
        {
          "enabledPlugins": {"existing@market": true},
          "statusLine": {"type": "command", "command": "echo hi"},
          "permissions": {"allow": ["Bash"]},
          "env": {"FOO": "bar"}
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.setPluginEnabled(id: "new@market", enabled: true)

        let data = try Data(contentsOf: file)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ep = obj?["enabledPlugins"] as? [String: Bool]
        #expect(ep?["existing@market"] == true)
        #expect(ep?["new@market"] == true)
        // 모르는 키 보존
        #expect(obj?["statusLine"] != nil)
        #expect(obj?["permissions"] != nil)
        #expect((obj?["env"] as? [String: String])?["FOO"] == "bar")
    }

    @Test("mutation 직전 백업 파일 1개 생성")
    func snapshotCreatedBeforeWrite() async throws {
        let (file, backupDir) = freshSettings(#"{"enabledPlugins":{}}"#)
        defer { cleanup(file, backupDir: backupDir) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.setPluginEnabled(id: "a@b", enabled: true)

        let entries = try FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil
        )
        #expect(entries.count == 1)
    }

    @Test("setMarketplaceAutoUpdate — 토글 성공")
    func toggleAutoUpdate_existing() async throws {
        let (file, backupDir) = freshSettings(#"""
        {
          "extraKnownMarketplaces": {
            "foo": {"source": {"source": "git", "url": "x"}, "autoUpdate": false}
          }
        }
        """#)
        defer { cleanup(file, backupDir: backupDir) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        try await writer.setMarketplaceAutoUpdate(name: "foo", autoUpdate: true)

        let data = try Data(contentsOf: file)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ekm = obj?["extraKnownMarketplaces"] as? [String: Any]
        let entry = ekm?["foo"] as? [String: Any]
        #expect(entry?["autoUpdate"] as? Bool == true)
        // source 도 보존
        let source = entry?["source"] as? [String: Any]
        #expect(source?["source"] as? String == "git")
        #expect(source?["url"] as? String == "x")
    }

    @Test("setMarketplaceAutoUpdate — 미선언 마켓 throw")
    func toggleAutoUpdate_missingMarket_throws() async throws {
        let (file, backupDir) = freshSettings(#"{"extraKnownMarketplaces":{}}"#)
        defer { cleanup(file, backupDir: backupDir) }

        let writer = SettingsWriter(
            fileURL: file,
            backup: BackupService(backupDir: backupDir, limit: 5)
        )
        await #expect(throws: SettingsWriter.WriterError.self) {
            try await writer.setMarketplaceAutoUpdate(name: "absent", autoUpdate: true)
        }
    }

    @Test("settings.json 미존재 → fileMissing throw")
    func missingFile_throws() async {
        let bogus = URL(fileURLWithPath: "/no/such/settings-\(UUID().uuidString).json")
        let writer = SettingsWriter(
            fileURL: bogus,
            backup: BackupService(backupDir: bogus.deletingLastPathComponent(), limit: 5)
        )
        await #expect(throws: SettingsWriter.WriterError.self) {
            try await writer.setPluginEnabled(id: "a@b", enabled: true)
        }
    }

    private func freshSettings(_ json: String) -> (URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-pm-sw-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "settings.json", directoryHint: .notDirectory)
        let backupDir = dir.appending(path: "backups", directoryHint: .isDirectory)
        try? Data(json.utf8).write(to: file)
        return (file, backupDir)
    }

    private func cleanup(_ file: URL, backupDir: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
