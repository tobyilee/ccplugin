import Foundation

/// `claude` CLI 호출 래퍼.
///
/// 모든 호출은 ProcessRunner 를 통과 — 쉘 미사용 (PRD §5.1).
/// 경로 해석은 ClaudeCLIPathResolver 에 위임 (PRD §5.2).
public actor ClaudeCLI {

    public enum CLIError: Error, Sendable {
        case nonZeroExit(arguments: [String], exitCode: Int32, stderr: String)
        case decodeFailed(arguments: [String], stdout: String, underlying: Error)
    }

    private let runner: ProcessRunner
    private let resolver: ClaudeCLIPathResolver

    public init(
        runner: ProcessRunner = FoundationProcessRunner(),
        resolver: ClaudeCLIPathResolver = ClaudeCLIPathResolver()
    ) {
        self.runner = runner
        self.resolver = resolver
    }

    /// 임의 인자로 `claude` 호출. exit code 0 외에는 throw 하지 않음 (caller 가 판단).
    public func run(
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> ProcessResult {
        let executable = try await resolver.resolve()
        return try await runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    /// `claude` 호출 후 exit 0 강제. 그 외엔 `CLIError.nonZeroExit` throw.
    public func runRequiringSuccess(
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> ProcessResult {
        let result = try await run(arguments: arguments, environment: environment, timeout: timeout)
        guard result.ok else {
            throw CLIError.nonZeroExit(
                arguments: arguments,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    /// `claude ... --json` 호출 후 stdout 을 Codable 타입으로 디코드.
    public func runJSON<T: Decodable>(
        _ type: T.Type,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> T {
        let result = try await runRequiringSuccess(
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw CLIError.decodeFailed(
                arguments: arguments,
                stdout: result.stdout,
                underlying: NSError(domain: "ClaudeCLI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "stdout 이 UTF-8 변환 실패"
                ])
            )
        }
        do {
            return try JSONCoding.decoder().decode(T.self, from: data)
        } catch {
            throw CLIError.decodeFailed(
                arguments: arguments,
                stdout: result.stdout,
                underlying: error
            )
        }
    }

    /// `claude --version` 호출 결과.
    public func version() async throws -> String {
        let result = try await runRequiringSuccess(arguments: ["--version"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
