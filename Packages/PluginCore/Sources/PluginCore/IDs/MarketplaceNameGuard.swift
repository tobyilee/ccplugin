import Foundation

/// Marketplace 이름 사칭 + 비ASCII (homograph) 차단.
///
/// PRD §1.4 + Claude Code `schemas.ts:19` `ALLOWED_OFFICIAL_MARKETPLACE_NAMES`
/// + `schemas.ts:71` `BLOCKED_OFFICIAL_NAME_PATTERN` 미러.
///
/// 공식 예약 이름은 `github.com/anthropics/*` 출처만 허용 — name + source 동시 검증.
public enum MarketplaceNameGuard {

    /// 공식 예약 이름 화이트리스트 (Claude Code `schemas.ts:19-28` 미러).
    /// 이 이름들은 anthropics 출처만 사용 가능.
    public static let allowedOfficialNames: Set<String> = [
        "claude-code-marketplace",
        "claude-code-plugins",
        "claude-plugins-official",
        "anthropic-marketplace",
        "anthropic-plugins",
        "agent-skills",
        "life-sciences",
        "knowledge-work-plugins",
    ]

    /// 검증 결과.
    public enum Verdict: Equatable, Sendable {
        case allowed
        case blocked(BlockReason)
    }

    public enum BlockReason: String, Equatable, Sendable {
        /// 비ASCII 문자 포함 — homograph attack 차단.
        case nonASCII
        /// 공식 예약 이름인데 anthropics 출처가 아님 — 사칭.
        case officialNameWithNonAnthropicsSource
        /// `BLOCKED_OFFICIAL_NAME_PATTERN` 매칭 — 공식 사칭 시도.
        case impersonatesOfficial
        /// 빈 문자열.
        case empty
    }

    /// 이름만 검증 — source 미제공 시 보수적.
    /// 화이트리스트 이름은 source 검증을 매니저가 별도로 호출하도록 `.allowed` 로 통과.
    public static func validate(name: String) -> Verdict {
        if name.isEmpty { return .blocked(.empty) }
        if !name.allSatisfy(\.isASCII) { return .blocked(.nonASCII) }
        if allowedOfficialNames.contains(name) { return .allowed }
        if matchesBlockedPattern(name) { return .blocked(.impersonatesOfficial) }
        return .allowed
    }

    /// 이름 + source 동시 검증. 가장 정확한 형식.
    public static func validate(name: String, source: MarketplaceSource) -> Verdict {
        if name.isEmpty { return .blocked(.empty) }
        if !name.allSatisfy(\.isASCII) { return .blocked(.nonASCII) }
        if allowedOfficialNames.contains(name) {
            return isAnthropicsSource(source)
                ? .allowed
                : .blocked(.officialNameWithNonAnthropicsSource)
        }
        if matchesBlockedPattern(name) { return .blocked(.impersonatesOfficial) }
        return .allowed
    }

    /// 편의: validate 결과가 `.allowed` 인지.
    public static func isAllowed(name: String) -> Bool {
        if case .allowed = validate(name: name) { return true } else { return false }
    }

    public static func isAllowed(name: String, source: MarketplaceSource) -> Bool {
        if case .allowed = validate(name: name, source: source) { return true } else { return false }
    }

    // MARK: - 내부

    private static func matchesBlockedPattern(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return blockedRegex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// `github.com/anthropics/*` 출처 인지 검사.
    private static func isAnthropicsSource(_ source: MarketplaceSource) -> Bool {
        switch source {
        case .github(let repo, _, _, _):
            return repo.lowercased().hasPrefix("anthropics/")
        case .git(let url, _, _, _):
            let lower = url.lowercased()
            return lower.hasPrefix("https://github.com/anthropics/")
                || lower.hasPrefix("http://github.com/anthropics/")
                || lower.hasPrefix("git@github.com:anthropics/")
                || lower.hasPrefix("ssh://git@github.com/anthropics/")
        default:
            return false
        }
    }

    /// Claude Code `schemas.ts:71` 의 `BLOCKED_OFFICIAL_NAME_PATTERN` 미러.
    /// case-insensitive.
    // swiftlint:disable:next force_try
    private static let blockedRegex = try! NSRegularExpression(
        pattern: #"(?:official[^a-z0-9]*(anthropic|claude)|(?:anthropic|claude)[^a-z0-9]*official|^(?:anthropic|claude)[^a-z0-9]*(marketplace|plugins|official))"#,
        options: [.caseInsensitive]
    )
}
