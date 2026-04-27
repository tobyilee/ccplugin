import Foundation

/// `~/.claude/settings.json` (또는 project/local 동등 파일) 의 매니저-관심 필드 read.
///
/// 동일한 actor 패턴을 InstalledReader / MarketplaceReader 와 공유.
/// 파일이 없는 정상 시나리오 (project scope 미설정 등) 는 caller 가 `fileNotFound` 를 흡수해서
/// 빈 subset 으로 처리하는 패턴 권장.
public actor SettingsReader {

    public enum ReaderError: Error, Sendable {
        case fileNotFound(URL)
        case readFailed(URL, underlying: Error)
        case decodeFailed(URL, underlying: Error)
    }

    private let fileURL: URL

    /// 기본은 user-scope (`~/.claude/settings.json`).
    /// project / local scope 는 호출 측이 별도 URL 로 인스턴스 생성.
    public init(fileURL: URL = ClaudePaths.userSettingsFile) {
        self.fileURL = fileURL
    }

    public func load() async throws -> ManagerSettingsSubset {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReaderError.fileNotFound(fileURL)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ReaderError.readFailed(fileURL, underlying: error)
        }
        do {
            return try JSONCoding.decoder().decode(ManagerSettingsSubset.self, from: data)
        } catch {
            throw ReaderError.decodeFailed(fileURL, underlying: error)
        }
    }

    public var watchedURL: URL { fileURL }
}
