import Foundation

/// `claude` CLI 바이너리 경로 해석.
///
/// PRD §5.2 fallback chain:
/// 1. `CC_PM_CLAUDE_BIN` 환경변수 (사용자 명시)
/// 2. 알려진 위치 스캔 (`/opt/homebrew/bin/claude` 등)
/// 3. (옵션, GUI 컨텍스트 한정) 로그인 셸 위임 — 본 모듈은 미구현
/// 4. (옵션, GUI 컨텍스트 한정) 사용자 NSOpenPanel — 본 모듈은 미구현
///
/// 검증: 해석된 경로로 `claude --version` 호출하여 exit 0 확인.
public actor ClaudeCLIPathResolver {

    public enum ResolveError: Error, Equatable, Sendable {
        case notFound
        case notExecutable(URL)
        case versionCheckFailed(URL, exitCode: Int32, stderr: String)
    }

    private let runner: ProcessRunner
    private let environment: [String: String]
    private var cached: URL?

    public init(
        runner: ProcessRunner = FoundationProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.environment = environment
    }

    /// 알려진 후보 경로. 우선순위 순. `~` 는 호출 시 expand.
    public static let knownCandidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.bun/bin/claude",
    ]

    /// 해석된 경로 반환. 캐시된 값이 있으면 재사용.
    public func resolve() async throws -> URL {
        if let cached { return cached }
        let resolved = try await resolveFresh()
        cached = resolved
        return resolved
    }

    /// 캐시 무효화 후 재해석.
    public func reset() async {
        cached = nil
    }

    private func resolveFresh() async throws -> URL {
        // 1. CC_PM_CLAUDE_BIN
        if let override = environment["CC_PM_CLAUDE_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try await verify(url)
            return url
        }

        // 2. 알려진 위치 스캔
        for candidate in Self.knownCandidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                do {
                    try await verify(url)
                    return url
                } catch {
                    continue  // 다음 후보로
                }
            }
        }

        throw ResolveError.notFound
    }

    /// `claude --version` 호출하여 exit 0 검증.
    private func verify(_ url: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ResolveError.notExecutable(url)
        }
        let result = try await runner.run(
            executable: url,
            arguments: ["--version"],
            environment: nil,
            timeout: .seconds(5)
        )
        guard result.ok else {
            throw ResolveError.versionCheckFailed(
                url,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }
}
