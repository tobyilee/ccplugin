import Foundation

/// Marketplace 의 출처 (discriminator: `source` 필드).
///
/// PRD §1.6 + Claude Code `schemas.ts:906` `MarketplaceSourceSchema` 미러.
/// `settings` source (인라인 선언) 는 디스크에 직렬화되지 않으므로 미포함.
public enum MarketplaceSource: Codable, Sendable, Equatable {
    case url(url: String, headers: [String: String]?)
    case github(repo: String, ref: String?, path: String?, sparsePaths: [String]?)
    case git(url: String, ref: String?, path: String?, sparsePaths: [String]?)
    case npm(package: String)
    case file(path: String)
    case directory(path: String)
    case hostPattern(String)
    case pathPattern(String)

    private enum CodingKeys: String, CodingKey {
        case source
        case url
        case repo
        case ref
        case path
        case sparsePaths
        case package
        case headers
        case hostPattern
        case pathPattern
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .source)
        switch type {
        case "url":
            self = .url(
                url: try c.decode(String.self, forKey: .url),
                headers: try c.decodeIfPresent([String: String].self, forKey: .headers)
            )
        case "github":
            self = .github(
                repo: try c.decode(String.self, forKey: .repo),
                ref: try c.decodeIfPresent(String.self, forKey: .ref),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                sparsePaths: try c.decodeIfPresent([String].self, forKey: .sparsePaths)
            )
        case "git":
            self = .git(
                url: try c.decode(String.self, forKey: .url),
                ref: try c.decodeIfPresent(String.self, forKey: .ref),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                sparsePaths: try c.decodeIfPresent([String].self, forKey: .sparsePaths)
            )
        case "npm":
            self = .npm(package: try c.decode(String.self, forKey: .package))
        case "file":
            self = .file(path: try c.decode(String.self, forKey: .path))
        case "directory":
            self = .directory(path: try c.decode(String.self, forKey: .path))
        case "hostPattern":
            self = .hostPattern(try c.decode(String.self, forKey: .hostPattern))
        case "pathPattern":
            self = .pathPattern(try c.decode(String.self, forKey: .pathPattern))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: c,
                debugDescription: "Unknown marketplace source type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .url(let url, let headers):
            try c.encode("url", forKey: .source)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(headers, forKey: .headers)
        case .github(let repo, let ref, let path, let sparsePaths):
            try c.encode("github", forKey: .source)
            try c.encode(repo, forKey: .repo)
            try c.encodeIfPresent(ref, forKey: .ref)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(sparsePaths, forKey: .sparsePaths)
        case .git(let url, let ref, let path, let sparsePaths):
            try c.encode("git", forKey: .source)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(ref, forKey: .ref)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(sparsePaths, forKey: .sparsePaths)
        case .npm(let package):
            try c.encode("npm", forKey: .source)
            try c.encode(package, forKey: .package)
        case .file(let path):
            try c.encode("file", forKey: .source)
            try c.encode(path, forKey: .path)
        case .directory(let path):
            try c.encode("directory", forKey: .source)
            try c.encode(path, forKey: .path)
        case .hostPattern(let value):
            try c.encode("hostPattern", forKey: .source)
            try c.encode(value, forKey: .hostPattern)
        case .pathPattern(let value):
            try c.encode("pathPattern", forKey: .source)
            try c.encode(value, forKey: .pathPattern)
        }
    }
}
