import Foundation

/// `~/.claude/settings.json` 의 `hooks` 블록 mirror.
///
/// PRD §F5. Claude Code `schemas.ts` 의 HooksConfigSchema 의 매니저-관심 subset.
/// 매니저는 hooks block read 와 add/remove 만 담당. 임의 PreToolUse 매처 같은 고급 schema 는
/// passthrough 로 보존.

/// 단일 hook 엔트리의 matcher — 문자열 또는 객체.
public enum HookMatcher: Decodable, Sendable, Equatable {
    case literal(String)
    case regex(pattern: String)
    case unknown

    public var displayText: String {
        switch self {
        case .literal(let s): return s
        case .regex(let p):   return "regex(\(p))"
        case .unknown:        return "<unknown>"
        }
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self = .literal(s)
            return
        }
        if let c = try? decoder.container(keyedBy: K.self) {
            if let pattern = try? c.decode(String.self, forKey: .pattern) {
                self = .regex(pattern: pattern)
                return
            }
        }
        self = .unknown
    }

    private enum K: String, CodingKey { case pattern, type }
}

public struct HookCommand: Decodable, Sendable, Equatable {
    public let type: String
    public let command: String
    public let timeout: Int?

    public init(type: String = "command", command: String, timeout: Int? = nil) {
        self.type = type
        self.command = command
        self.timeout = timeout
    }
}

public struct HookEntry: Decodable, Sendable, Equatable {
    /// Claude Code 의 `SessionStart`, `Stop`, `UserPromptSubmit` 등은 matcher 가 없는 게 정상.
    /// `PreToolUse`/`PostToolUse` 만 사실상 필수 — 매니저는 양쪽 모두 허용.
    public let matcher: HookMatcher?
    public let hooks: [HookCommand]
}

public typealias HooksByEvent = [String: [HookEntry]]
