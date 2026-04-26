import Foundation

/// `name@marketplace` 형식의 플러그인 식별자.
/// PRD §1.4 + Claude Code `schemas.ts:1339` `PluginIdSchema` 미러.
public enum PluginID {
    /// `^[a-z0-9][-a-z0-9._]*@[a-z0-9][-a-z0-9._]*$` (case-insensitive)
    /// Claude Code 의 정규식과 동일.
    public static func isValid(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return Self.regex.firstMatch(in: s, options: [], range: range)?.range == range
    }

    public struct Parsed: Sendable, Equatable {
        public let name: String
        public let marketplace: String?
    }

    public static func parse(_ s: String) -> Parsed {
        guard let at = s.firstIndex(of: "@") else {
            return Parsed(name: s, marketplace: nil)
        }
        return Parsed(
            name: String(s[..<at]),
            marketplace: String(s[s.index(after: at)...])
        )
    }

    public static func build(name: String, marketplace: String) -> String {
        "\(name)@\(marketplace)"
    }

    // swiftlint:disable:next force_try
    private static let regex = try! NSRegularExpression(
        pattern: "^[a-z0-9][-a-z0-9._]*@[a-z0-9][-a-z0-9._]*$",
        options: [.caseInsensitive]
    )
}
