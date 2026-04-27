import Foundation

/// `~/.claude/{skills,agents,commands}/` 에 사용자가 직접 작성한 자산 스캔.
///
/// PRD §F4: plugin-managed 자산은 `~/.claude/plugins/cache/<market>/<plugin>/...` 안쪽이라
/// 자연스럽게 제외됨. 본 reader 는 user-owned 만 반환.
public actor UserAssetReader {

    public enum AssetKind: String, Sendable, Equatable, CaseIterable {
        case skill, agent, command
    }

    public struct Asset: Identifiable, Sendable, Equatable {
        public var id: String { "\(kind.rawValue)/\(name)" }
        public let kind: AssetKind
        public let name: String
        public let path: URL
    }

    private let configDir: URL

    public init(configDir: URL = ClaudePaths.configDir) {
        self.configDir = configDir
    }

    public func loadAll() async -> [Asset] {
        var all: [Asset] = []
        all.append(contentsOf: scanSkills())
        all.append(contentsOf: scanFlatMarkdown(.agent, sub: "agents"))
        all.append(contentsOf: scanFlatMarkdown(.command, sub: "commands"))
        return all.sorted { $0.id < $1.id }
    }

    private func scanSkills() -> [Asset] {
        let dir = configDir.appending(path: "skills", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { entry in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let skillFile = entry.appending(path: "SKILL.md", directoryHint: .notDirectory)
            guard fm.fileExists(atPath: skillFile.path) else { return nil }
            return Asset(kind: .skill, name: entry.lastPathComponent, path: entry)
        }
    }

    private func scanFlatMarkdown(_ kind: AssetKind, sub: String) -> [Asset] {
        let dir = configDir.appending(path: sub, directoryHint: .isDirectory)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { Asset(kind: kind, name: $0.deletingPathExtension().lastPathComponent, path: $0) }
    }
}
