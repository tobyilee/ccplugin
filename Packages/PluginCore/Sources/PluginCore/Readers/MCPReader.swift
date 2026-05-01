import Foundation

/// 설치된 MCP 서버 인벤토리 reader.
///
/// 두 source 의 합집합:
/// 1. **user-scope**: `~/.claude.json#mcpServers` (claude mcp add 로 등록).
/// 2. **plugin-bundled**: 각 플러그인의 `<installPath>/.mcp.json#mcpServers`.
///
/// enable/disable 은 Claude Code 가 per-project 로 관리하므로
/// `~/.claude.json#projects[<path>]` 의 세 배열을 모두 읽어 합산한다:
/// - `disabledMcpServers` → user-scope MCP 의 disable 표시.
/// - `disabledMcpjsonServers` → plugin-bundled MCP 의 disable 표시.
/// - `enabledMcpjsonServers` → plugin-bundled MCP 의 explicit-allow (UI 표시 영향 없음, 쓰기 시만 사용).
///
/// 실패 source 는 빈 값으로 흡수 — 부분 결과라도 표시 가능.
public actor MCPReader {

    public init() {}

    /// 플러그인 목록을 받아 해당 플러그인들의 `.mcp.json` + 사용자 `~/.claude.json` 을 합쳐
    /// 통합 MCP 목록 반환.
    ///
    /// - Parameters:
    ///   - plugins: `(id, installPath)` 튜플 목록. id 는 `name@market` 형식.
    ///   - claudeJSONPath: `~/.claude.json` 경로 (테스트 주입 가능).
    public func readAll(
        plugins: [(id: String, installPath: URL)],
        claudeJSONPath: URL = ClaudePaths.userClaudeJSONFile
    ) async -> [MCP] {
        let projectsState = readProjectsState(at: claudeJSONPath)
        let userServers = readUserScopeServers(at: claudeJSONPath)

        var result: [MCP] = []

        // user-scope: ~/.claude.json#mcpServers
        for (name, spec) in userServers {
            let disabledIn = projectsState.disabledUser[name] ?? []
            result.append(MCP(
                name: name,
                source: .user,
                command: spec.command,
                args: spec.args,
                isEnabledEverywhere: disabledIn.isEmpty,
                disabledInProjects: disabledIn.sorted()
            ))
        }

        // plugin-bundled: 각 플러그인의 <installPath>/.mcp.json#mcpServers
        for plugin in plugins {
            let bundled = readPluginMCPServers(installPath: plugin.installPath)
            for (name, spec) in bundled {
                let disabledIn = projectsState.disabledJSON[name] ?? []
                result.append(MCP(
                    name: name,
                    source: .plugin(pluginID: plugin.id, installPath: plugin.installPath),
                    command: spec.command,
                    args: spec.args,
                    isEnabledEverywhere: disabledIn.isEmpty,
                    disabledInProjects: disabledIn.sorted()
                ))
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.sourceLabel != rhs.sourceLabel {
                return lhs.sourceLabel < rhs.sourceLabel
            }
            return lhs.name < rhs.name
        }
    }

    // MARK: - 표시용 spec

    private struct ServerSpec {
        let command: String?
        let args: [String]?
    }

    private func extractSpec(_ raw: Any) -> ServerSpec {
        guard let dict = raw as? [String: Any] else {
            return ServerSpec(command: nil, args: nil)
        }
        let command = dict["command"] as? String
        let args = dict["args"] as? [String]
        return ServerSpec(command: command, args: args)
    }

    // MARK: - ~/.claude.json 읽기

    /// 한 번 읽고 두 가지 결과 반환:
    /// - `disabledUser[serverName]` = 그 서버를 disable 한 프로젝트 path 들.
    /// - `disabledJSON[serverName]` = 그 서버를 disable 한 프로젝트 path 들.
    private struct ProjectsState {
        var disabledUser: [String: [String]] = [:]
        var disabledJSON: [String: [String]] = [:]
    }

    private func readProjectsState(at url: URL) -> ProjectsState {
        var state = ProjectsState()
        guard let root = readJSONObject(at: url),
              let projects = root["projects"] as? [String: Any] else {
            return state
        }
        for (projectPath, raw) in projects {
            guard let entry = raw as? [String: Any] else { continue }
            if let arr = entry["disabledMcpServers"] as? [String] {
                for name in arr {
                    state.disabledUser[name, default: []].append(projectPath)
                }
            }
            if let arr = entry["disabledMcpjsonServers"] as? [String] {
                for name in arr {
                    state.disabledJSON[name, default: []].append(projectPath)
                }
            }
        }
        return state
    }

    private func readUserScopeServers(at url: URL) -> [(name: String, spec: ServerSpec)] {
        guard let root = readJSONObject(at: url),
              let dict = root["mcpServers"] as? [String: Any] else {
            return []
        }
        return dict.map { (name: $0.key, spec: extractSpec($0.value)) }
    }

    // MARK: - <installPath>/.mcp.json 읽기

    private func readPluginMCPServers(installPath: URL) -> [(name: String, spec: ServerSpec)] {
        let file = installPath.appending(path: ".mcp.json", directoryHint: .notDirectory)
        guard let root = readJSONObject(at: file),
              let dict = root["mcpServers"] as? [String: Any] else {
            return []
        }
        return dict.map { (name: $0.key, spec: extractSpec($0.value)) }
    }

    // MARK: - 공통 IO

    private func readJSONObject(at url: URL) -> [String: Any]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
