import Foundation

/// MCP 라이프사이클 CLI 위임.
///
/// `claude mcp` 서브커맨드 중 매니저가 사용하는 verb 만 노출. enable/disable verb 는
/// CLI 가 제공하지 않으므로 (per-project disable 배열 직접 mutation 으로 대체) 여기 없음.
public actor MCPOperations {

    private let cli: ClaudeCLI

    public init(cli: ClaudeCLI = ClaudeCLI()) {
        self.cli = cli
    }

    /// User-scope MCP 등록 제거 — `claude mcp remove <name>`.
    /// `~/.claude.json#mcpServers` 에서 키를 제거한다.
    /// 플러그인 번들 MCP 에는 적용 불가 — 그쪽은 disable-only.
    public func removeUserScope(name: String) async throws {
        _ = try await cli.runRequiringSuccess(
            arguments: ["mcp", "remove", name]
        )
    }
}
