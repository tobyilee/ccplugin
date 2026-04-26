import Foundation

/// `~/.claude/plugins/known_marketplaces.json` 의 entry 1개.
///
/// PRD §7.2 + Claude Code `schemas.ts:1624` `KnownMarketplacesFileSchema` 미러.
public struct KnownMarketplaceEntry: Codable, Sendable, Equatable {
    public let source: MarketplaceSource
    public let installLocation: String
    public let lastUpdated: Date
    public let autoUpdate: Bool?

    public init(
        source: MarketplaceSource,
        installLocation: String,
        lastUpdated: Date,
        autoUpdate: Bool? = nil
    ) {
        self.source = source
        self.installLocation = installLocation
        self.lastUpdated = lastUpdated
        self.autoUpdate = autoUpdate
    }
}

/// `known_marketplaces.json` 파일 자체.
/// Top-level 이 `[name: KnownMarketplaceEntry]` 형식이라 typealias.
public typealias KnownMarketplacesFile = [String: KnownMarketplaceEntry]

extension KnownMarketplaceEntry {
    public static func decodeFile(from data: Data) throws -> KnownMarketplacesFile {
        try JSONCoding.decoder().decode(KnownMarketplacesFile.self, from: data)
    }

    public static func encodeFile(_ file: KnownMarketplacesFile) throws -> Data {
        try JSONCoding.encoder().encode(file)
    }
}
