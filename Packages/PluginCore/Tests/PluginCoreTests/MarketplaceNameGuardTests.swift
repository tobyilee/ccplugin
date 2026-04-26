import Testing
import Foundation
@testable import PluginCore

@Suite("MarketplaceNameGuard — name only")
struct MarketplaceNameGuardNameOnlyTests {

    // MARK: - 화이트리스트 (8개) — name only 검증에서는 통과

    @Test("공식 예약 이름은 name-only 에서 allowed",
          arguments: Array(MarketplaceNameGuard.allowedOfficialNames))
    func allowedOfficialNames_passNameOnly(_ name: String) {
        #expect(MarketplaceNameGuard.validate(name: name) == .allowed)
    }

    // MARK: - BLOCKED_OFFICIAL_PATTERN positive

    @Test("공식 사칭 패턴 차단", arguments: [
        "official-anthropic",          // official + anthropic
        "official.anthropic.x",
        "official_claude",
        "anthropic-official",          // anthropic + official
        "claude-official-x",
        "anthropic-marketplace-fake",  // ^anthropic-marketplace 시작
        "anthropic_plugins_evil",
        "anthropic-official",
        "claude-marketplace-fake",     // ^claude-marketplace 시작
        "claude-plugins-evil",
        "claude_official",
        "claude.official",
        "anthropic.marketplace",
        "OFFICIAL-CLAUDE",             // 대소문자 무관
        "Official_Anthropic_Tools"
    ])
    func blockedPatternMatches(_ name: String) {
        let v = MarketplaceNameGuard.validate(name: name)
        #expect(v == .blocked(.impersonatesOfficial), "name=\(name) 차단 기대, got \(v)")
    }

    // MARK: - 비ASCII 차단

    @Test("비ASCII 이름 차단 (homograph attack 방지)", arguments: [
        "анthropic-plugins",  // Cyrillic а
        "claude-plügins",     // German ü
        "我的-marketplace",     // Chinese
        "claude-市場",
        "🚀-rocket",           // emoji
        "ｃｌａｕｄｅ-fullwidth"
    ])
    func nonASCII_blocked(_ name: String) {
        let v = MarketplaceNameGuard.validate(name: name)
        #expect(v == .blocked(.nonASCII), "name=\(name) nonASCII 차단 기대, got \(v)")
    }

    // MARK: - 빈 문자열

    @Test("빈 이름 거절")
    func emptyName_blocked() {
        #expect(MarketplaceNameGuard.validate(name: "") == .blocked(.empty))
    }

    // MARK: - 정상 통과 케이스

    @Test("일반 이름 통과", arguments: [
        "feature-dev",
        "my-cool-plugin",
        "x",
        "ralph-marketplace",          // 공식 사칭 패턴 매치 안 함
        "harness-marketplace",
        "toby-plugins",
        "openai-codex",
        "my.plugin.com",
        "kebab-case-2026",
        "ALL_CAPS_AND_dots.123"
    ])
    func normalNames_allowed(_ name: String) {
        #expect(MarketplaceNameGuard.validate(name: name) == .allowed)
    }

    // MARK: - boolean helper

    @Test("isAllowed convenience")
    func isAllowed_helper() {
        #expect(MarketplaceNameGuard.isAllowed(name: "feature-dev"))
        #expect(!MarketplaceNameGuard.isAllowed(name: "anthropic-official-fake"))
    }
}

@Suite("MarketplaceNameGuard — name + source")
struct MarketplaceNameGuardWithSourceTests {

    @Test("공식 예약 이름 + anthropics github source = allowed")
    func reservedName_anthropicsGithub_allowed() {
        let source = MarketplaceSource.github(repo: "anthropics/claude-plugins-official", ref: nil, path: nil, sparsePaths: nil)
        #expect(MarketplaceNameGuard.validate(name: "claude-plugins-official", source: source) == .allowed)
    }

    @Test("공식 예약 이름 + anthropics git url (https) = allowed")
    func reservedName_anthropicsGitHttps_allowed() {
        let source = MarketplaceSource.git(url: "https://github.com/anthropics/claude-plugins-official.git", ref: nil, path: nil, sparsePaths: nil)
        #expect(MarketplaceNameGuard.validate(name: "claude-plugins-official", source: source) == .allowed)
    }

    @Test("공식 예약 이름 + anthropics git url (ssh) = allowed")
    func reservedName_anthropicsGitSsh_allowed() {
        let source = MarketplaceSource.git(url: "git@github.com:anthropics/anthropic-plugins.git", ref: nil, path: nil, sparsePaths: nil)
        #expect(MarketplaceNameGuard.validate(name: "anthropic-plugins", source: source) == .allowed)
    }

    @Test("공식 예약 이름 + 비-anthropics github = 사칭 차단")
    func reservedName_nonAnthropicsGithub_blocked() {
        let source = MarketplaceSource.github(repo: "evil/anthropic-plugins", ref: nil, path: nil, sparsePaths: nil)
        let v = MarketplaceNameGuard.validate(name: "anthropic-plugins", source: source)
        #expect(v == .blocked(.officialNameWithNonAnthropicsSource))
    }

    @Test("공식 예약 이름 + 비-anthropics git = 사칭 차단")
    func reservedName_nonAnthropicsGit_blocked() {
        let source = MarketplaceSource.git(url: "https://gitlab.com/evil/claude-plugins-official.git", ref: nil, path: nil, sparsePaths: nil)
        let v = MarketplaceNameGuard.validate(name: "claude-plugins-official", source: source)
        #expect(v == .blocked(.officialNameWithNonAnthropicsSource))
    }

    @Test("공식 예약 이름 + npm/file/directory source = 사칭 차단")
    func reservedName_nonGit_blocked() {
        let cases: [MarketplaceSource] = [
            .npm(package: "anthropic-plugins"),
            .file(path: "/local/anthropic-plugins/marketplace.json"),
            .directory(path: "/local/anthropic-plugins")
        ]
        for source in cases {
            let v = MarketplaceNameGuard.validate(name: "anthropic-plugins", source: source)
            #expect(v == .blocked(.officialNameWithNonAnthropicsSource), "source=\(source) 차단 기대")
        }
    }

    @Test("비-예약 이름 + 임의 source = allowed")
    func normalName_anySource_allowed() {
        let source = MarketplaceSource.git(url: "https://github.com/random/repo.git", ref: nil, path: nil, sparsePaths: nil)
        #expect(MarketplaceNameGuard.validate(name: "random-marketplace", source: source) == .allowed)
    }

    @Test("BLOCKED 패턴 이름 + anthropics source 라도 차단")
    func blockedPattern_evenWithAnthropicsSource_blocked() {
        // 화이트리스트에 없는 이름이지만 BLOCKED_OFFICIAL_PATTERN 매칭
        let source = MarketplaceSource.github(repo: "anthropics/whatever", ref: nil, path: nil, sparsePaths: nil)
        let v = MarketplaceNameGuard.validate(name: "anthropic-marketplace-fake", source: source)
        #expect(v == .blocked(.impersonatesOfficial),
               "패턴 매칭은 source 와 무관하게 차단 (이 이름은 화이트리스트 미포함)")
    }

    @Test("Anthropic 출처 검증은 case-insensitive")
    func anthropicsSource_caseInsensitive() {
        let cases: [MarketplaceSource] = [
            .github(repo: "Anthropics/claude-plugins-official", ref: nil, path: nil, sparsePaths: nil),
            .github(repo: "ANTHROPICS/claude-plugins-official", ref: nil, path: nil, sparsePaths: nil),
            .git(url: "https://GitHub.com/Anthropics/claude-plugins-official.git", ref: nil, path: nil, sparsePaths: nil)
        ]
        for source in cases {
            #expect(MarketplaceNameGuard.validate(name: "claude-plugins-official", source: source) == .allowed,
                   "case-insensitive 매칭 기대: \(source)")
        }
    }
}
