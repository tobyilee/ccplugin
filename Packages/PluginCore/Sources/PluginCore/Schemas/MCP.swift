import Foundation

/// 인벤토리 한 행에 해당하는 MCP 서버.
///
/// "설치된 MCP" 는 두 source 의 합집합:
/// - **user**: `~/.claude.json#mcpServers` 의 키 (claude mcp add 로 등록).
/// - **plugin**: 설치된 플러그인의 `<installPath>/.mcp.json#mcpServers` 의 키.
///
/// enable/disable 상태는 Claude Code 가 **per-project** 로 관리한다
/// (`~/.claude.json#projects[<path>].disabledMcpServers / disabledMcpjsonServers / enabledMcpjsonServers`).
/// 매니저는 "모든 현재 프로젝트에 일괄 적용" 모델을 채택하므로, 한 MCP 가 *어느 한* 프로젝트에서라도
/// disabled 면 `isEnabledEverywhere = false` 로 표시한다.
public struct MCP: Identifiable, Hashable, Sendable {

    public enum Source: Hashable, Sendable {
        /// 플러그인이 번들한 `.mcp.json` 에서 유래. enable/disable 은 `disabledMcpjsonServers` 에 적용.
        case plugin(pluginID: String, installPath: URL)
        /// `~/.claude.json#mcpServers` 의 user-scope 등록. enable/disable 은 `disabledMcpServers` 에 적용.
        case user
    }

    /// 서버 이름 — `mcpServers` dict 의 키.
    public let name: String
    public let source: Source
    /// 표시용 — `command` 필드 (있다면).
    public let command: String?
    /// 표시용 — `args` 배열 (있다면).
    public let args: [String]?
    /// 어느 프로젝트에서도 disabled 가 아닐 때만 true.
    public let isEnabledEverywhere: Bool
    /// 이 MCP 가 disabled 인 프로젝트 path 목록 (정렬됨).
    public let disabledInProjects: [String]

    /// `Identifiable` — source 와 name 을 함께 고려해 user-scope 와 plugin-scope 가 겹쳐도 충돌 없음.
    public var id: String {
        switch source {
        case .user:
            return "user::\(name)"
        case .plugin(let pluginID, _):
            return "plugin::\(pluginID)::\(name)"
        }
    }

    public init(
        name: String,
        source: Source,
        command: String? = nil,
        args: [String]? = nil,
        isEnabledEverywhere: Bool,
        disabledInProjects: [String] = []
    ) {
        self.name = name
        self.source = source
        self.command = command
        self.args = args
        self.isEnabledEverywhere = isEnabledEverywhere
        self.disabledInProjects = disabledInProjects
    }

    /// UI 표시용 "Plugin: foo" / "User" 라벨.
    public var sourceLabel: String {
        switch source {
        case .user: return "User"
        case .plugin(let pluginID, _):
            // pluginID 는 보통 `name@market` 형식 — name 만 뽑아 표시.
            let head = pluginID.split(separator: "@", maxSplits: 1).first.map(String.init) ?? pluginID
            return "Plugin: \(head)"
        }
    }
}
