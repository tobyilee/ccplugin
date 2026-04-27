import Foundation

/// Cache 디렉토리의 orphan 정리.
///
/// PRD §F2.3 / Q2 spike RESOLVED: marketplace remove 가 메타데이터 cascade 는 자동
/// 처리하지만 `~/.claude/plugins/cache/<market>/<plugin>/<version>/` 디렉토리는
/// orphan 으로 남김. 본 actor 가 그 정리 책임.
public actor CacheCleanup {

    public struct Plan: Sendable, Equatable {
        public let orphanedDirs: [URL]
    }

    public struct Result: Sendable, Equatable {
        public let removed: [URL]
        public let failed: [(url: URL, message: String)]

        public init(removed: [URL] = [], failed: [(url: URL, message: String)] = []) {
            self.removed = removed
            self.failed = failed
        }

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.removed == rhs.removed
                && lhs.failed.count == rhs.failed.count
                && zip(lhs.failed, rhs.failed).allSatisfy { $0.url == $1.url && $0.message == $1.message }
        }
    }

    private let cacheDir: URL
    private let installedReader: InstalledReader

    public init(
        cacheDir: URL = ClaudePaths.cacheDir,
        installedReader: InstalledReader = InstalledReader()
    ) {
        self.cacheDir = cacheDir
        self.installedReader = installedReader
    }

    /// dry-run 계획 — 어떤 디렉토리가 제거 대상인지 반환만, 실제 삭제 안 함.
    public func plan() async -> Plan {
        let installedPaths = await loadInstalledPaths()
        return Plan(orphanedDirs: scanOrphans(installedPaths: installedPaths))
    }

    /// 실제 정리 실행. 사전에 plan() 으로 미리보기 권장.
    public func execute() async -> Result {
        let installedPaths = await loadInstalledPaths()
        let orphans = scanOrphans(installedPaths: installedPaths)
        var removed: [URL] = []
        var failed: [(URL, String)] = []
        let fm = FileManager.default
        for orphan in orphans {
            do {
                try fm.removeItem(at: orphan)
                removed.append(orphan)
            } catch {
                failed.append((orphan, "\(error)"))
            }
        }
        return Result(removed: removed, failed: failed)
    }

    private func loadInstalledPaths() async -> Set<String> {
        guard let installed = try? await installedReader.load() else { return [] }
        return Set(
            installed.plugins.values.flatMap { entries in
                entries.map {
                    URL(fileURLWithPath: $0.installPath).standardizedFileURL.path
                }
            }
        )
    }

    private func scanOrphans(installedPaths: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let markets = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var orphans: [URL] = []
        for marketDir in markets where isDir(marketDir, fm: fm) {
            guard let plugins = try? fm.contentsOfDirectory(
                at: marketDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for pluginDir in plugins where isDir(pluginDir, fm: fm) {
                guard let versions = try? fm.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for versionDir in versions where isDir(versionDir, fm: fm) {
                    let path = versionDir.standardizedFileURL.path
                    if !installedPaths.contains(path) {
                        orphans.append(versionDir)
                    }
                }
            }
        }
        return orphans
    }

    private func isDir(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
