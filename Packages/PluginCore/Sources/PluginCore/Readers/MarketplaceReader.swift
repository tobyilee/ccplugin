import Foundation

/// `known_marketplaces.json` + 각 마켓의 `marketplace.json` 파서.
public actor MarketplaceReader {

    public enum ReaderError: Error, Sendable {
        case fileNotFound(URL)
        case readFailed(URL, underlying: Error)
        case decodeFailed(URL, underlying: Error)
    }

    /// `marketplace.json` 의 plugin entry (필수 필드만).
    /// 전체 schema 미러는 PluginManifest 와 합쳐서 별도 작업.
    public struct PluginCatalogEntry: Codable, Sendable, Equatable {
        public let name: String
        public let description: String?
        public let category: String?
        public let homepage: String?
        public let version: String?
        public let keywords: [String]?
        // source 는 string("./...") 또는 객체 형식 둘 다 허용 — 별도 처리 필요. 여기선 raw JSON 으로.
        // 매니저 view 에서 이 entry 를 합성할 때 처리.
    }

    /// `marketplace.json` 의 owner 정보.
    public struct MarketplaceOwner: Codable, Sendable, Equatable {
        public let name: String
        public let email: String?
    }

    /// `marketplace.json` 의 `metadata` 객체 — 일부 마켓 (e.g. openai-codex) 에서만 존재.
    /// version 은 매니저 UI 에 표시되어 사용자가 최신 카탈로그인지 가늠하도록 함.
    public struct MarketplaceMetadata: Codable, Sendable, Equatable {
        public let description: String?
        public let version: String?
    }

    /// `marketplace.json` 자체 (최상위).
    /// `$schema` / root `description` 같은 추가 키는 spike Q11 에서 발견된 micro-drift —
    /// `passthrough` 패턴으로 보존 (Codable 상으론 무시).
    /// description 은 root 와 `metadata.description` 두 위치 모두 합법 → `effectiveDescription` 사용.
    public struct MarketplaceCatalog: Codable, Sendable {
        public let name: String
        public let description: String?
        public let owner: MarketplaceOwner?
        public let metadata: MarketplaceMetadata?
        public let plugins: [PluginCatalogEntry]

        /// `metadata.version` — 별칭. nil 이면 마켓이 버전을 declared 하지 않은 것.
        public var effectiveVersion: String? { metadata?.version }

        /// root `description` 우선, 없으면 `metadata.description` fallback.
        public var effectiveDescription: String? { description ?? metadata?.description }
    }

    private let knownFileURL: URL
    private let marketplacesDir: URL

    public init(
        knownFileURL: URL = ClaudePaths.knownMarketplacesFile,
        marketplacesDir: URL = ClaudePaths.marketplacesDir
    ) {
        self.knownFileURL = knownFileURL
        self.marketplacesDir = marketplacesDir
    }

    public func loadKnown() async throws -> KnownMarketplacesFile {
        guard FileManager.default.fileExists(atPath: knownFileURL.path) else {
            throw ReaderError.fileNotFound(knownFileURL)
        }
        let data: Data
        do {
            data = try Data(contentsOf: knownFileURL)
        } catch {
            throw ReaderError.readFailed(knownFileURL, underlying: error)
        }
        do {
            return try KnownMarketplaceEntry.decodeFile(from: data)
        } catch {
            throw ReaderError.decodeFailed(knownFileURL, underlying: error)
        }
    }

    /// 단일 마켓의 `marketplace.json` 로딩.
    /// `installLocation` 을 직접 받으면 directory source 마켓도 처리 가능 (default 디렉토리 외부).
    public func loadCatalog(at installLocation: URL) async throws -> MarketplaceCatalog {
        let catalogURL = installLocation
            .appending(path: ".claude-plugin", directoryHint: .isDirectory)
            .appending(path: "marketplace.json", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw ReaderError.fileNotFound(catalogURL)
        }
        let data: Data
        do {
            data = try Data(contentsOf: catalogURL)
        } catch {
            throw ReaderError.readFailed(catalogURL, underlying: error)
        }
        do {
            return try JSONCoding.decoder().decode(MarketplaceCatalog.self, from: data)
        } catch {
            throw ReaderError.decodeFailed(catalogURL, underlying: error)
        }
    }

    /// 알려진 마켓 모두 로드. 실패한 항목은 스킵 + 결과의 `errors` 에 누적.
    public func loadAllCatalogs() async throws -> (catalogs: [String: MarketplaceCatalog], errors: [String: Error]) {
        let known = try await loadKnown()
        var catalogs: [String: MarketplaceCatalog] = [:]
        var errors: [String: Error] = [:]
        for (name, entry) in known {
            let installLocation = URL(fileURLWithPath: entry.installLocation)
            do {
                catalogs[name] = try await loadCatalog(at: installLocation)
            } catch {
                errors[name] = error
            }
        }
        return (catalogs, errors)
    }
}
