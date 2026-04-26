import Foundation

/// `~/.claude/plugins/installed_plugins.json` 파서.
/// Actor 격리로 파일 읽기 동시성 안전.
public actor InstalledReader {

    public enum ReaderError: Error, Sendable {
        case fileNotFound(URL)
        case readFailed(URL, underlying: Error)
        case decodeFailed(URL, underlying: Error)
    }

    private let fileURL: URL

    public init(fileURL: URL = ClaudePaths.installedPluginsFile) {
        self.fileURL = fileURL
    }

    public func load() async throws -> InstalledPluginsFileV2 {
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
            return try InstalledPluginsFileV2.decode(from: data)
        } catch {
            throw ReaderError.decodeFailed(fileURL, underlying: error)
        }
    }

    public var watchedURL: URL { fileURL }
}
