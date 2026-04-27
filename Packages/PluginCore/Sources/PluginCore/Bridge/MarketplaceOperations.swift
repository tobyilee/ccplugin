import Foundation

/// Marketplace 라이프사이클 CLI 위임.
///
/// PRD §F2 / M2 critical path. 모든 mutation 은 `claude plugin marketplace` 서브커맨드 위임.
/// CLI 가 `extraKnownMarketplaces` cascade 를 자동으로 처리 (Q2 spike RESOLVED).
///
/// 에러는 `ClaudeCLI.CLIError` 가 그대로 전파 — UI 가 stderr 메시지를 사용자에게 노출.
public actor MarketplaceOperations {

    private let cli: ClaudeCLI

    public init(cli: ClaudeCLI = ClaudeCLI()) {
        self.cli = cli
    }

    /// 모든 마켓 갱신 (CLI 의 `update [name]` 미지정 = 전체).
    /// PRD §F2.4 Refresh All.
    public func refreshAll() async throws {
        _ = try await cli.runRequiringSuccess(arguments: ["plugin", "marketplace", "update"])
    }

    /// 단일 마켓 갱신.
    public func refresh(name: String) async throws {
        _ = try await cli.runRequiringSuccess(arguments: ["plugin", "marketplace", "update", name])
    }

    /// 마켓 제거. cascade (소속 플러그인 자동 uninstall) 는 CLI 가 처리.
    /// cache 디렉토리 orphan 만 별도 OrphanedCacheDetector 가 처리 (M2 후속).
    public func remove(name: String) async throws {
        _ = try await cli.runRequiringSuccess(arguments: ["plugin", "marketplace", "remove", name])
    }

    /// 마켓 추가. `--ref` / `--auto-update` / `--path` 는 CLI 미지원 →
    /// add 후 settings.json 직접 mutation 으로 백필 (PRD §F2.2).
    public func add(
        source: String,
        scope: PluginScope = .user,
        sparsePaths: [String] = []
    ) async throws {
        var args = ["plugin", "marketplace", "add", source, "--scope", scope.rawValue]
        if !sparsePaths.isEmpty {
            args.append("--sparse")
            args.append(contentsOf: sparsePaths)
        }
        _ = try await cli.runRequiringSuccess(arguments: args)
    }
}
