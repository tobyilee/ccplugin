import Foundation

/// 외부 프로세스 실행 단일 진입점.
///
/// PRD §5.1 강제: `executableURL` (절대 경로) + `arguments: [String]` 만 사용.
/// 사용자 입력은 모두 `arguments` 배열로만 전달 — `posix_spawn(2)` 가 직접 argv 로
/// 위임하므로 쉘 메타문자 (`;`, `|`, `$(...)`) 가 무력화됨.
///
/// 금지 패턴:
/// - `/bin/sh -c "..."` 같은 쉘 위임
/// - deprecated `Process.launchPath`
/// - 사용자 입력을 문자열로 이어 붙여 명령 라인 조립
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case timeout
    case spawnFailed(String)
    case executableNotFound(URL)
}

public protocol ProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration
    ) async throws -> ProcessResult
}

extension ProcessRunner {
    public func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: nil, timeout: .seconds(120))
    }

    public func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: nil, timeout: timeout)
    }
}

/// `Foundation.Process` 기반 default 구현.
///
/// 보안 보장:
/// - `executableURL` 명시 (PATH 검색 안 함, 절대 경로 강제)
/// - `arguments` 가 그대로 argv 로 전달 (쉘 해석 안 됨)
/// - `standardInput = .nullDevice` (stdin 격리)
public struct FoundationProcessRunner: ProcessRunner {

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration
    ) async throws -> ProcessResult {
        // 존재 여부 사전 체크 — 디버깅 친화적 에러 메시지
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = executable        // 절대 경로 강제
        process.arguments = arguments              // 사용자 입력은 여기로만
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice  // stdin 격리

        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await Self.waitTermination(process: process,
                                               stdoutPipe: stdoutPipe,
                                               stderrPipe: stderrPipe)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // timeout 발동 — 자식 프로세스에 SIGTERM 보내 즉시 정리.
                if process.isRunning {
                    process.terminate()
                }
                throw ProcessRunnerError.timeout
            }
            do {
                guard let first = try await group.next() else {
                    throw ProcessRunnerError.spawnFailed("task group empty")
                }
                group.cancelAll()
                return first
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                group.cancelAll()
                throw error
            }
        }
    }

    /// 프로세스 spawn + 종료 대기. terminationHandler 가 단 한 번 fire.
    private static func waitTermination(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let result = ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessRunnerError.spawnFailed("\(error)"))
            }
        }
    }
}
