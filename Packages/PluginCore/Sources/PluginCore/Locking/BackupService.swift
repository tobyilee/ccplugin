import Foundation

/// 모든 mutation 직전에 호출하는 백업 서비스.
///
/// PRD §10.x / NFR: "mutation 직전 백업 파일 항상 생성".
/// 정책:
/// - 백업 위치: 기본 `<configDir>/cc-pm-backups/`
/// - 파일명: `<original>.<ISO8601>.bak`
/// - retention: 기본 최대 20개 (오래된 것부터 삭제)
public struct BackupService: Sendable {

    public enum BackupError: Error, Sendable {
        case sourceMissing(URL)
        case backupDirCreation(URL, underlying: Error)
        case copyFailed(URL, URL, underlying: Error)
    }

    public let backupDir: URL
    public let limit: Int

    public init(
        backupDir: URL = BackupService.defaultDir,
        limit: Int = 20
    ) {
        self.backupDir = backupDir
        self.limit = max(1, limit)
    }

    public static var defaultDir: URL {
        ClaudePaths.configDir.appending(path: "cc-pm-backups", directoryHint: .isDirectory)
    }

    /// `source` 의 현재 상태를 backupDir 에 timestamped 사본으로 보관.
    /// 반환값: 생성된 백업 파일 URL.
    @discardableResult
    public func snapshot(_ source: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw BackupError.sourceMissing(source)
        }
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            throw BackupError.backupDirCreation(backupDir, underlying: error)
        }
        let stamp = Self.timestamp()
        let target = backupDir.appending(
            path: "\(source.lastPathComponent).\(stamp).bak",
            directoryHint: .notDirectory
        )
        do {
            try fm.copyItem(at: source, to: target)
        } catch {
            throw BackupError.copyFailed(source, target, underlying: error)
        }
        prune()
        return target
    }

    /// 보관 한도를 초과한 오래된 백업 제거.
    private func prune() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return l > r  // 최신이 앞으로
        }
        for old in sorted.dropFirst(limit) {
            try? fm.removeItem(at: old)
        }
    }

    /// 파일명에 안전한 ISO8601 타임스탬프 (콜론 → 하이픈).
    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
