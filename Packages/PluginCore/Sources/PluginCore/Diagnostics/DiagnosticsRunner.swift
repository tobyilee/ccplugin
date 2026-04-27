import Foundation

/// 매니저 통합 진단.
///
/// PRD §F5. 가벼운 disk 검사로 사용자가 자주 부딪히는 문제를 미리 표면화:
/// 1. `installed_plugins.json` 의 entry 인데 manifest 누락
/// 2. cache 디렉토리 orphan (Q2 spike: marketplace remove 후 cache 미정리)
/// 3. blocklist.json 등록 항목 (info)
///
/// 더 비싼 검사 (loadErrors 같은 runtime 정보) 는 CLI 통합 후 추가 (M4 후속).
public actor DiagnosticsRunner {

    public struct Diagnostic: Identifiable, Sendable, Equatable {
        public enum Severity: String, Sendable, Equatable {
            case info, warning, error
        }
        public var id: String { "\(severity.rawValue)/\(category)/\(message)" }
        public let severity: Severity
        public let category: String
        public let message: String

        public init(severity: Severity, category: String, message: String) {
            self.severity = severity
            self.category = category
            self.message = message
        }
    }

    public init() {}

    public func runAll() async -> [Diagnostic] {
        var diags: [Diagnostic] = []
        diags.append(contentsOf: await checkMissingManifests())
        diags.append(contentsOf: await checkOrphanedCache())
        diags.append(contentsOf: checkBlocklist())
        return diags.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return Self.severityRank(lhs.severity) < Self.severityRank(rhs.severity)
            }
            return lhs.id < rhs.id
        }
    }

    private static func severityRank(_ s: Diagnostic.Severity) -> Int {
        switch s {
        case .error:   return 0
        case .warning: return 1
        case .info:    return 2
        }
    }

    private func checkMissingManifests() async -> [Diagnostic] {
        let reader = InstalledReader()
        guard let installed = try? await reader.load() else { return [] }
        let fm = FileManager.default
        var diags: [Diagnostic] = []
        for (id, entries) in installed.plugins {
            for entry in entries {
                let manifest = URL(fileURLWithPath: entry.installPath)
                    .appending(path: ".claude-plugin/plugin.json", directoryHint: .notDirectory)
                if !fm.fileExists(atPath: manifest.path) {
                    diags.append(Diagnostic(
                        severity: .warning,
                        category: "manifest",
                        message: "\(id) (\(entry.scope.rawValue)): plugin.json 누락 — \(entry.installPath)"
                    ))
                }
            }
        }
        return diags
    }

    private func checkOrphanedCache() async -> [Diagnostic] {
        let cacheDir = ClaudePaths.cacheDir
        let fm = FileManager.default
        let installed = (try? await InstalledReader().load())
        let installedPaths = Set(
            installed?.plugins.values.flatMap { entries in
                entries.map {
                    URL(fileURLWithPath: $0.installPath).standardizedFileURL.path
                }
            } ?? []
        )

        guard let markets = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var diags: [Diagnostic] = []
        for marketDir in markets where isDir(marketDir, fm: fm) {
            guard let plugins = try? fm.contentsOfDirectory(
                at: marketDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for pluginDir in plugins where isDir(pluginDir, fm: fm) {
                guard let versions = try? fm.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for versionDir in versions where isDir(versionDir, fm: fm) {
                    let path = versionDir.standardizedFileURL.path
                    if !installedPaths.contains(path) {
                        diags.append(Diagnostic(
                            severity: .info,
                            category: "orphaned-cache",
                            message: "\(marketDir.lastPathComponent)/\(pluginDir.lastPathComponent)/\(versionDir.lastPathComponent): no installed entry"
                        ))
                    }
                }
            }
        }
        return diags
    }

    private func checkBlocklist() -> [Diagnostic] {
        let file = ClaudePaths.blocklistFile
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { entry in
            guard let plugin = entry["plugin"] as? String else { return nil }
            return Diagnostic(
                severity: .info,
                category: "blocklist",
                message: "\(plugin): blocked"
            )
        }
    }

    private func isDir(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
