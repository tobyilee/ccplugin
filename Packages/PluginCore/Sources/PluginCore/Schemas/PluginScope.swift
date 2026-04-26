import Foundation

/// Plugin 활성화/설치 범위.
/// PRD §1.5 + Claude Code `schemas.ts` `PluginScopeSchema` 미러.
public enum PluginScope: String, Codable, CaseIterable, Sendable {
    case managed
    case user
    case project
    case local
}
