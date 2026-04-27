import Foundation

/// `~/.claude/settings.json` 의 매니저-관심 필드만 추출한 read-only subset.
///
/// PRD §7.3 기반. M1 read-only inventory 가 필요로 하는 키 + M4 hooks 표시용:
/// - `enabledPlugins` — Layer 1 intent: 어떤 플러그인이 켜져 있는가.
/// - `extraKnownMarketplaces` — 어떤 마켓이 user/project/local settings 에 선언되었는가.
/// - `hooks` — settings.json hooks 블록 (PreToolUse, Stop, SessionStart 등).
///
/// **재인코딩 금지**: 의도적으로 `Codable` 이 아닌 `Decodable` 만 채택.
/// settings.json 의 모든 미지원 키 (statusLine, env, permissions 등) 가 손실되기 때문.
/// 쓰기는 SettingsWriter (JSONSerialization 기반 passthrough) 가 별도 구현.
public struct ManagerSettingsSubset: Decodable, Sendable, Equatable {
    public let enabledPlugins: [String: Bool]?
    public let extraKnownMarketplaces: [String: ExtraKnownMarketplaceEntry]?
    public let hooks: HooksByEvent?

    public init(
        enabledPlugins: [String: Bool]? = nil,
        extraKnownMarketplaces: [String: ExtraKnownMarketplaceEntry]? = nil,
        hooks: HooksByEvent? = nil
    ) {
        self.enabledPlugins = enabledPlugins
        self.extraKnownMarketplaces = extraKnownMarketplaces
        self.hooks = hooks
    }
}

/// settings.json 의 `extraKnownMarketplaces[name]` 엔트리.
///
/// `installLocation` / `lastUpdated` 는 settings 에 없음 (known_marketplaces.json 쪽 책임).
/// 매니저 view 는 두 reader 의 결과를 머지해서 SettingsOrigin 을 계산.
public struct ExtraKnownMarketplaceEntry: Decodable, Sendable, Equatable {
    public let source: MarketplaceSource
    public let autoUpdate: Bool?
}
