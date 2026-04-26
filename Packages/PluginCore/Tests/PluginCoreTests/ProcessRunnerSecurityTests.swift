import Testing
import Foundation
@testable import PluginCore

/// PRD §5.1 보안 가드 검증 — 가장 critical.
///
/// 모든 사용자 입력은 `arguments: [String]` 배열로만 전달되어 `posix_spawn(2)` 가 직접
/// argv 로 위임 → 쉘 메타문자 (`;`, `|`, `$(...)`) 가 무력화됨을 검증.
@Suite("ProcessRunner — security guarantees")
struct ProcessRunnerSecurityTests {

    let runner = FoundationProcessRunner()
    let echo = URL(fileURLWithPath: "/bin/echo")
    let trueBin = URL(fileURLWithPath: "/usr/bin/true")
    let falseBin = URL(fileURLWithPath: "/usr/bin/false")

    @Test("쉘 메타문자가 argv 로 그대로 전달됨 (해석 안 됨)",
          arguments: [
            ";",
            "|",
            "$(rm -rf /)",
            "&&",
            "`whoami`",
            "$HOME",
            ">/tmp/cc-pm-spike-evil-redirect"
          ])
    func shellMetacharsArePreserved(_ payload: String) async throws {
        // /bin/echo 는 argv 를 그대로 stdout 에 출력
        let result = try await runner.run(executable: echo, arguments: [payload])
        #expect(result.ok)
        #expect(result.stdout.trimmingCharacters(in: .newlines) == payload,
               "쉘 해석되었다면 \(payload) 가 그대로 출력되지 않았을 것")
    }

    @Test("악성 redirect 시도가 파일을 만들지 못함")
    func redirectAttemptDoesNotCreateFile() async throws {
        let evilPath = "/tmp/cc-pm-spike-evil-redirect-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: evilPath)
        }
        // 사용자 입력으로 ">$evilPath" 가 들어왔다고 가정
        let _ = try await runner.run(
            executable: echo,
            arguments: ["malicious", ">", evilPath]
        )
        // 쉘이었다면 redirect 되어 파일 생성됐을 것. argv 로 가니 echo 가 그냥 ">" 와 경로를 출력만.
        #expect(!FileManager.default.fileExists(atPath: evilPath),
               "쉘 redirect 가 해석되어 파일이 생성됨 — 보안 가드 깨짐!")
    }

    @Test("멀티 인자 그대로 전달")
    func multipleArgumentsPreserved() async throws {
        let result = try await runner.run(
            executable: echo,
            arguments: ["foo", "bar baz", "qux"]
        )
        #expect(result.ok)
        // /bin/echo 기본 동작: 인자를 공백으로 join
        #expect(result.stdout.trimmingCharacters(in: .newlines) == "foo bar baz qux")
    }

    @Test("exit code 0 (true)")
    func trueExitsZero() async throws {
        let result = try await runner.run(executable: trueBin, arguments: [])
        #expect(result.exitCode == 0)
        #expect(result.ok)
    }

    @Test("exit code 1 (false)")
    func falseExitsNonZero() async throws {
        let result = try await runner.run(executable: falseBin, arguments: [])
        #expect(result.exitCode == 1)
        #expect(!result.ok)
    }

    @Test("존재하지 않는 바이너리는 ProcessRunnerError.executableNotFound throw")
    func nonExistentExecutable_throws() async {
        let bogus = URL(fileURLWithPath: "/no/such/binary-\(UUID().uuidString)")
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run(executable: bogus, arguments: [])
        }
    }

    @Test("환경변수 격리 — 명시한 env 만 전달")
    func environmentIsolation() async throws {
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let result = try await runner.run(
            executable: env,
            arguments: [],
            environment: ["CC_PM_TEST_MARKER": "spike-marker-42"],
            timeout: .seconds(5)
        )
        #expect(result.ok)
        #expect(result.stdout.contains("CC_PM_TEST_MARKER=spike-marker-42"))
        // 부모 env 의 PATH 등이 새지 않음 (격리 확인은 옵션)
    }

    @Test("timeout 발동", .timeLimit(.minutes(1)))
    func timeoutTriggers() async {
        let sleepBin = URL(fileURLWithPath: "/bin/sleep")
        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await runner.run(
                executable: sleepBin,
                arguments: ["10"],
                environment: nil,
                timeout: .seconds(1)
            )
        }
    }
}

@Suite("ClaudeCLIPathResolver — 본인 환경 검증")
struct ClaudeCLIPathResolverTests {

    @Test("현재 환경에서 claude 경로 해석 성공")
    func resolvesInRealEnvironment() async throws {
        let resolver = ClaudeCLIPathResolver()
        let url = try await resolver.resolve()
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(url.lastPathComponent == "claude")
    }

    @Test("CC_PM_CLAUDE_BIN env override 우선")
    func envOverrideTakesPrecedence() async throws {
        // 본인 환경의 실제 경로
        let realResolver = ClaudeCLIPathResolver()
        let realPath = try await realResolver.resolve()

        let resolver = ClaudeCLIPathResolver(
            environment: ["CC_PM_CLAUDE_BIN": realPath.path]
        )
        let url = try await resolver.resolve()
        #expect(url.path == realPath.path)
    }

    @Test("존재하지 않는 CC_PM_CLAUDE_BIN 은 throw")
    func badOverride_throws() async {
        let resolver = ClaudeCLIPathResolver(
            environment: ["CC_PM_CLAUDE_BIN": "/no/such/claude-\(UUID().uuidString)"]
        )
        await #expect(throws: ClaudeCLIPathResolver.ResolveError.self) {
            _ = try await resolver.resolve()
        }
    }

    @Test("resolve 결과는 캐시됨")
    func resolveIsCached() async throws {
        let resolver = ClaudeCLIPathResolver()
        let first = try await resolver.resolve()
        let second = try await resolver.resolve()
        #expect(first == second)
    }
}

@Suite("ClaudeCLI — 본인 환경 통합")
struct ClaudeCLIIntegrationTests {

    @Test("claude --version 호출 성공")
    func versionWorks() async throws {
        let cli = ClaudeCLI()
        let v = try await cli.version()
        #expect(v.contains("Claude Code"), "version 출력 형식 변경됨? 실측: '\(v)'")
    }

    @Test("claude plugin list --json 디코드 성공")
    func pluginListJSON() async throws {
        // CLI 출력 구조 (M0 spike 검증):
        //   [{ id, version, scope, enabled, installPath, ... }]
        struct ListItem: Decodable {
            let id: String
            let scope: String
            let enabled: Bool
            let installPath: String
        }

        let cli = ClaudeCLI()
        let items: [ListItem] = try await cli.runJSON(
            [ListItem].self,
            arguments: ["plugin", "list", "--json"]
        )
        #expect(items.count >= 26, "spike 시점 26개. 본인 환경 변동 가능")
        #expect(items.allSatisfy { !$0.id.isEmpty })
        #expect(items.allSatisfy { $0.installPath.hasPrefix("/") })
    }

    @Test("claude plugin marketplace list --json 디코드 성공")
    func marketplaceListJSON() async throws {
        struct MarketItem: Decodable {
            let name: String
            let source: String
            let installLocation: String
        }

        let cli = ClaudeCLI()
        let items: [MarketItem] = try await cli.runJSON(
            [MarketItem].self,
            arguments: ["plugin", "marketplace", "list", "--json"]
        )
        #expect(items.count >= 6, "spike 시점 6개")
    }
}
