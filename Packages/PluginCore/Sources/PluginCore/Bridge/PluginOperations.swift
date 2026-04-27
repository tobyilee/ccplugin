import Foundation

/// Plugin 라이프사이클 CLI 위임 — install / uninstall / enable / disable / update.
///
/// PRD §F1 / M3 critical path. 전부 `claude plugin <verb>` 서브커맨드 위임.
/// 에러는 `ClaudeCLI.CLIError` 가 그대로 전파.
///
/// 직접 fallback (boolean flip 만) 은 `SettingsWriter.setPluginEnabled` 가 담당
/// — CLI 호출 0.5–2초 vs 직접 < 10ms 의 UX 차이 (PRD §6.1).
public actor PluginOperations {

    private let cli: ClaudeCLI

    public init(cli: ClaudeCLI = ClaudeCLI()) {
        self.cli = cli
    }

    /// 마켓의 플러그인 설치. `id` 는 `name@market` 형식.
    public func install(id: String, scope: PluginScope = .user) async throws {
        _ = try await cli.runRequiringSuccess(
            arguments: ["plugin", "install", id, "--scope", scope.rawValue]
        )
    }

    /// 플러그인 uninstall. `--keep-data` 시 `~/.claude/plugins/data/<plugin>-<market>/` 보존.
    public func uninstall(id: String, scope: PluginScope, keepData: Bool = false) async throws {
        var args = ["plugin", "uninstall", id, "--scope", scope.rawValue]
        if keepData {
            args.append("--keep-data")
        }
        _ = try await cli.runRequiringSuccess(arguments: args)
    }

    /// 플러그인 enable. CLI 가 dependency 자동 활성화 처리.
    public func enable(id: String, scope: PluginScope) async throws {
        _ = try await cli.runRequiringSuccess(
            arguments: ["plugin", "enable", id, "--scope", scope.rawValue]
        )
    }

    /// 플러그인 disable. scope 미지정 시 CLI auto-detect.
    public func disable(id: String, scope: PluginScope? = nil) async throws {
        var args = ["plugin", "disable", id]
        if let scope = scope {
            args.append("--scope")
            args.append(scope.rawValue)
        }
        _ = try await cli.runRequiringSuccess(arguments: args)
    }

    /// 플러그인 update. "restart required to apply" — Layer 3 reload 안내 필요.
    public func update(id: String, scope: PluginScope) async throws {
        _ = try await cli.runRequiringSuccess(
            arguments: ["plugin", "update", id, "--scope", scope.rawValue]
        )
    }
}
