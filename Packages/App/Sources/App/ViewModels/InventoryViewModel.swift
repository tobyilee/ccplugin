import Foundation
import SwiftUI
import PluginCore

/// 디스크 4-source 합성 view model.
///
/// PRD §F1.1 명시:  CLI + installed_plugins V2 + manifest + 디렉토리 스캔.
/// M1 read-only 단계는 CLI 를 의존하지 않음 (GUI PATH 흡수 미해결, Q1):
/// - `installed_plugins.json` V2: 어디 / 어느 scope 에 설치되어 있는가
/// - `settings.json` (user-scope): `enabledPlugins` + `extraKnownMarketplaces`
/// - `<installPath>/.claude-plugin/plugin.json`: presentation (description, author, …)
/// - `<installPath>/{commands,agents,skills,hooks,...}` 디렉토리: component 카운트
///
/// 실패한 source 는 빈 값으로 흡수해 UI 가 부분 결과라도 표시 가능.
@MainActor
final class InventoryViewModel: ObservableObject {

    @Published private(set) var items: [PluginInventoryRow] = []
    @Published private(set) var marketplaces: [MarketplaceRow] = []
    @Published private(set) var availablePlugins: [BrowsePluginRow] = []
    @Published private(set) var hooks: HooksByEvent? = nil
    @Published private(set) var mcps: [MCP] = []
    @Published private(set) var userAssets: [UserAssetReader.Asset] = []
    @Published private(set) var diagnostics: [DiagnosticsRunner.Diagnostic] = []
    @Published private(set) var lastError: String? = nil
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isMutating: Bool = false
    @Published private(set) var isDiagnosing: Bool = false
    @Published var needsReload: Bool = false

    var enabledCount: Int { items.filter(\.enabled).count }

    private let installedReader: InstalledReader
    private let settingsReader: SettingsReader
    private let marketplaceReader: MarketplaceReader
    private let manifestReader: PluginManifestReader
    private let mcpReader: MCPReader
    private let userAssetReader: UserAssetReader
    private let settingsWriter: SettingsWriter
    private let claudeJSONWriter: ClaudeJSONWriter
    private let marketOps: MarketplaceOperations
    private let pluginOps: PluginOperations
    private let mcpOps: MCPOperations
    private let diagnosticsRunner: DiagnosticsRunner
    private let cacheCleanup: CacheCleanup

    private var watcher: FSEventsWatcher?
    private var debounceTask: Task<Void, Never>?

    init(
        installedReader: InstalledReader = InstalledReader(),
        settingsReader: SettingsReader = SettingsReader(),
        marketplaceReader: MarketplaceReader = MarketplaceReader(),
        manifestReader: PluginManifestReader = PluginManifestReader(),
        mcpReader: MCPReader = MCPReader(),
        settingsWriter: SettingsWriter = SettingsWriter(),
        claudeJSONWriter: ClaudeJSONWriter = ClaudeJSONWriter(),
        marketOps: MarketplaceOperations = MarketplaceOperations(),
        pluginOps: PluginOperations = PluginOperations(),
        mcpOps: MCPOperations = MCPOperations(),
        userAssetReader: UserAssetReader = UserAssetReader(),
        diagnosticsRunner: DiagnosticsRunner = DiagnosticsRunner(),
        cacheCleanup: CacheCleanup = CacheCleanup()
    ) {
        self.installedReader = installedReader
        self.settingsReader = settingsReader
        self.marketplaceReader = marketplaceReader
        self.manifestReader = manifestReader
        self.mcpReader = mcpReader
        self.settingsWriter = settingsWriter
        self.claudeJSONWriter = claudeJSONWriter
        self.marketOps = marketOps
        self.pluginOps = pluginOps
        self.mcpOps = mcpOps
        self.userAssetReader = userAssetReader
        self.diagnosticsRunner = diagnosticsRunner
        self.cacheCleanup = cacheCleanup
        startWatching()
    }

    deinit {
        watcher?.stop()
        debounceTask?.cancel()
    }

    /// `~/.claude` 트리 변경 감지 → debounced reload.
    /// PRD §M2: FSEventsWatcher → 변경 자동 감지.
    private func startWatching() {
        // ~/.claude.json 은 ~/.claude/ 와 sibling — 별도 path 로 추가해야 외부 `claude mcp add` 등을 감지.
        let paths: [URL] = [
            ClaudePaths.pluginsDir,
            ClaudePaths.configDir,
            ClaudePaths.userClaudeJSONFile,
        ]
        let w = FSEventsWatcher(paths: paths, latency: 0.5)
        w.start { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDebouncedReload()
            }
        }
        self.watcher = w
    }

    private func scheduleDebouncedReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await reload()
        }
    }

    func reload() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // 4-source 병렬 로드.
        async let installedTask = installedReader.load()
        async let settingsTask = safeSettings()
        async let knownTask = safeKnown()
        async let catalogsTask = safeCatalogs()

        let installed: InstalledPluginsFileV2
        do {
            installed = try await installedTask
        } catch {
            self.items = []
            self.marketplaces = []
            self.lastError = "installed_plugins.json 로드 실패: \(error)"
            return
        }
        let settings = await settingsTask
        let known = await knownTask
        let catalogResult = await catalogsTask

        // Inventory rows.
        var rows: [PluginInventoryRow] = []
        var pluginInstallPaths: [(id: String, installPath: URL)] = []
        for (id, entries) in installed.plugins {
            // M1: user > project > local > 첫 번째 — 단일 행 표시. 멀티-scope 펼침은 M2+.
            let primary = entries.first(where: { $0.scope == .user })
                ?? entries.first(where: { $0.scope == .project })
                ?? entries.first(where: { $0.scope == .local })
                ?? entries.first
            guard let entry = primary else { continue }
            let installPath = URL(fileURLWithPath: entry.installPath)
            pluginInstallPaths.append((id: id, installPath: installPath))
            let manifest = try? await manifestReader.loadManifest(at: installPath)
            let counts = await manifestReader.countComponents(at: installPath)
            let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
            rows.append(PluginInventoryRow(
                id: id,
                name: parts.first ?? id,
                marketplace: parts.count > 1 ? parts[1] : "",
                version: entry.version ?? "unknown",
                scope: entry.scope,
                enabled: settings.enabledPlugins?[id] ?? false,
                description: manifest?.description,
                counts: counts
            ))
        }
        self.items = rows.sorted { $0.id < $1.id }

        // Marketplace rows.
        // autoUpdate 의 source-of-truth 는 settings.json (PRD §F2.5: 사용자 의도).
        // known_marketplaces.json 의 autoUpdate 는 일부 마켓에만 미러로 존재 — 단순 fallback.
        var mrows: [MarketplaceRow] = []
        for (name, entry) in known {
            let catalog = catalogResult.catalogs[name]
            let userIntent = settings.extraKnownMarketplaces?[name]?.autoUpdate
            let mirror = entry.autoUpdate
            let effectiveAutoUpdate = userIntent ?? mirror ?? false
            mrows.append(MarketplaceRow(
                name: name,
                sourceLabel: Self.sourceLabel(entry.source),
                autoUpdate: effectiveAutoUpdate,
                pluginCount: catalog?.plugins.count ?? 0,
                declaredInUserSettings: settings.extraKnownMarketplaces?[name] != nil,
                installLocation: entry.installLocation,
                version: catalog?.effectiveVersion,
                description: catalog?.effectiveDescription,
                lastUpdated: entry.lastUpdated
            ))
        }
        self.marketplaces = mrows.sorted { $0.name < $1.name }

        // Browse rows — 모든 마켓의 플러그인 cross-join + 설치 여부.
        var browse: [BrowsePluginRow] = []
        let installedIDs = Set(installed.plugins.keys)
        for (marketName, catalog) in catalogResult.catalogs {
            for plugin in catalog.plugins {
                let id = "\(plugin.name)@\(marketName)"
                browse.append(BrowsePluginRow(
                    name: plugin.name,
                    marketplace: marketName,
                    description: plugin.description,
                    version: plugin.version,
                    isInstalled: installedIDs.contains(id)
                ))
            }
        }
        self.availablePlugins = browse.sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled {
                return !lhs.isInstalled  // 미설치 우선
            }
            return lhs.id < rhs.id
        }

        if !catalogResult.errors.isEmpty {
            let names = catalogResult.errors.keys.sorted().joined(separator: ", ")
            self.lastError = "일부 마켓 catalog 로드 실패: \(names)"
        }

        // M4 add-ons (settings 의 hooks + user assets) — 비파괴적, 실패는 빈 값.
        self.hooks = settings.hooks
        self.userAssets = await userAssetReader.loadAll()
        self.mcps = await mcpReader.readAll(plugins: pluginInstallPaths)
    }

    // MARK: - M4 actions

    func runDiagnostics() async {
        isDiagnosing = true
        defer { isDiagnosing = false }
        self.diagnostics = await diagnosticsRunner.runAll()
    }

    func addHook(event: String, matcher: String, command: String, timeout: Int?) async {
        await runMutation(label: "addHook \(event)/\(matcher)") { [settingsWriter] in
            try await settingsWriter.addHook(
                event: event,
                matcher: matcher,
                command: command,
                timeout: timeout
            )
        }
    }

    func removeHook(event: String, at index: Int) async {
        await runMutation(label: "removeHook \(event)[\(index)]") { [settingsWriter] in
            try await settingsWriter.removeHook(event: event, at: index)
        }
    }

    // MARK: - MCP management

    /// MCP enable/disable. 모든 현재 프로젝트의 disable 배열에 일괄 적용.
    /// Optimistic UI: published `mcps` 행을 즉시 갱신.
    func setMCPEnabled(_ mcp: MCP, enabled: Bool) async {
        applyOptimisticMCPEnabled(id: mcp.id, enabled: enabled)
        let kind: ClaudeJSONWriter.MCPSourceKind
        switch mcp.source {
        case .user: kind = .user
        case .plugin: kind = .pluginJSON
        }
        let name = mcp.name
        await runMutation(label: enabled ? "enable mcp \(name)" : "disable mcp \(name)") {
            [claudeJSONWriter] in
            try await claudeJSONWriter.setMCPEnabledEverywhere(
                name: name,
                source: kind,
                enabled: enabled
            )
        }
    }

    /// User-scope MCP 제거 — `claude mcp remove <name>` 위임.
    /// 플러그인 번들 MCP 에는 호출 금지 (UI 단에서 차단).
    func removeMCP(_ mcp: MCP) async {
        guard case .user = mcp.source else {
            self.lastError = "Plugin-bundled MCP 는 제거 불가 (호스트 플러그인 uninstall 사용)"
            return
        }
        let name = mcp.name
        await runMutation(label: "remove mcp \(name)") { [mcpOps] in
            try await mcpOps.removeUserScope(name: name)
        }
    }

    private func applyOptimisticMCPEnabled(id: String, enabled: Bool) {
        guard let idx = mcps.firstIndex(where: { $0.id == id }) else { return }
        let old = mcps[idx]
        mcps[idx] = MCP(
            name: old.name,
            source: old.source,
            command: old.command,
            args: old.args,
            isEnabledEverywhere: enabled,
            disabledInProjects: enabled ? [] : old.disabledInProjects
        )
    }

    /// `claude plugin marketplace add` 위임 + 결과 반영.
    func addMarketplace(source: String, scope: PluginScope, sparsePaths: [String]) async {
        await runMutation(label: "addMarketplace \(source)") { [marketOps] in
            try await marketOps.add(source: source, scope: scope, sparsePaths: sparsePaths)
        }
    }

    /// orphan cache 정리 — Q2 spike 의 leftover 처리.
    func cleanOrphanedCache() async -> CacheCleanup.Result {
        isMutating = true
        defer { isMutating = false }
        let result = await cacheCleanup.execute()
        await reload()
        // 진단 재실행으로 orphan 카운트 갱신.
        self.diagnostics = await diagnosticsRunner.runAll()
        return result
    }

    func planOrphanedCacheCleanup() async -> CacheCleanup.Plan {
        await cacheCleanup.plan()
    }

    // MARK: - Mutating actions (M2)

    /// 명시적 autoUpdate 값 설정 — Toggle binding 의 newValue 를 그대로 전달받음.
    ///
    /// **Optimistic UI**: published `marketplaces` 행을 즉시 새 값으로 업데이트.
    /// Toggle binding 의 `get` 이 즉시 새 값을 반환 → SwiftUI 가 시각적으로 즉시 반영.
    /// 이후 reload 가 디스크 상태로 덮어씀 (mutation 성공 시 동일값, 실패 시 옛값으로 자동 revert).
    func setAutoUpdate(name: String, autoUpdate: Bool) async {
        applyOptimisticAutoUpdate(name: name, autoUpdate: autoUpdate)
        await runMutation(label: "auto-update \(autoUpdate ? "on" : "off")") {
            [settingsWriter] in
            try await settingsWriter.setMarketplaceAutoUpdate(
                name: name,
                autoUpdate: autoUpdate
            )
        }
    }

    private func applyOptimisticAutoUpdate(name: String, autoUpdate: Bool) {
        guard let idx = marketplaces.firstIndex(where: { $0.name == name }) else { return }
        let old = marketplaces[idx]
        marketplaces[idx] = MarketplaceRow(
            name: old.name,
            sourceLabel: old.sourceLabel,
            autoUpdate: autoUpdate,
            pluginCount: old.pluginCount,
            declaredInUserSettings: old.declaredInUserSettings,
            installLocation: old.installLocation,
            version: old.version,
            description: old.description,
            lastUpdated: old.lastUpdated
        )
    }

    func refreshAllMarketplaces() async {
        await runMutation(label: "Refresh All") { [marketOps] in
            try await marketOps.refreshAll()
        }
    }

    func refreshMarketplace(name: String) async {
        await runMutation(label: "Refresh \(name)") { [marketOps] in
            try await marketOps.refresh(name: name)
        }
    }

    func removeMarketplace(name: String) async {
        await runMutation(label: "Remove \(name)") { [marketOps] in
            try await marketOps.remove(name: name)
        }
    }

    // MARK: - Plugin lifecycle (M3)

    /// user-scope settings.json 의 enabledPlugins[id] 직접 flip — UX 우선 (PRD §6.1).
    /// Optimistic UI: published `items` 행을 즉시 업데이트해서 Toggle 시각 반영.
    func setPluginEnabled(id: String, enabled: Bool) async {
        applyOptimisticEnabled(id: id, enabled: enabled)
        await runMutation(label: enabled ? "enable \(id)" : "disable \(id)") {
            [settingsWriter] in
            try await settingsWriter.setPluginEnabled(id: id, enabled: enabled)
        }
    }

    private func applyOptimisticEnabled(id: String, enabled: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[idx]
        items[idx] = PluginInventoryRow(
            id: old.id,
            name: old.name,
            marketplace: old.marketplace,
            version: old.version,
            scope: old.scope,
            enabled: enabled,
            description: old.description,
            counts: old.counts
        )
    }

    /// 마켓 → 플러그인 install (CLI bridge).
    func installPlugin(id: String, scope: PluginScope) async {
        await runMutation(label: "install \(id) (\(scope.rawValue))") { [pluginOps] in
            try await pluginOps.install(id: id, scope: scope)
        }
    }

    /// 플러그인 uninstall (CLI bridge). cascade 는 CLI 가 처리.
    func uninstallPlugin(id: String, scope: PluginScope, keepData: Bool) async {
        await runMutation(label: "uninstall \(id)") { [pluginOps] in
            try await pluginOps.uninstall(id: id, scope: scope, keepData: keepData)
        }
    }

    /// 플러그인 update (CLI bridge).
    func updatePlugin(id: String, scope: PluginScope) async {
        await runMutation(label: "update \(id)") { [pluginOps] in
            try await pluginOps.update(id: id, scope: scope)
        }
    }

    private func runMutation(
        label: String,
        action: @escaping @Sendable () async throws -> Void
    ) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await action()
            needsReload = true
            await reload()
        } catch {
            self.lastError = "\(label) 실패: \(error)"
        }
    }

    // MARK: - 안전 래퍼 (실패는 빈 값으로 흡수)

    private func safeSettings() async -> ManagerSettingsSubset {
        (try? await settingsReader.load()) ?? ManagerSettingsSubset()
    }

    private func safeKnown() async -> KnownMarketplacesFile {
        (try? await marketplaceReader.loadKnown()) ?? [:]
    }

    private func safeCatalogs() async -> (
        catalogs: [String: MarketplaceReader.MarketplaceCatalog],
        errors: [String: Error]
    ) {
        (try? await marketplaceReader.loadAllCatalogs())
            ?? (catalogs: [:], errors: [:])
    }

    // MARK: - Source label

    static func sourceLabel(_ source: MarketplaceSource) -> String {
        switch source {
        case .url(let url, _):
            return "url · \(url)"
        case .github(let repo, let ref, _, _):
            return "github · \(repo)" + (ref.map { " @\($0)" } ?? "")
        case .git(let url, let ref, _, _):
            return "git · \(url)" + (ref.map { " @\($0)" } ?? "")
        case .npm(let pkg):
            return "npm · \(pkg)"
        case .file(let path):
            return "file · \(path)"
        case .directory(let path):
            return "directory · \(path)"
        case .hostPattern(let p):
            return "hostPattern · \(p)"
        case .pathPattern(let p):
            return "pathPattern · \(p)"
        }
    }
}

// MARK: - Row models

struct PluginInventoryRow: Identifiable, Equatable {
    let id: String
    let name: String
    let marketplace: String
    let version: String
    let scope: PluginScope
    let enabled: Bool
    let description: String?
    let counts: ComponentCounts
}

/// Browse 탭 행 — 모든 마켓 catalog 의 플러그인 + 설치 여부.
struct BrowsePluginRow: Identifiable, Equatable {
    var id: String { "\(name)@\(marketplace)" }
    let name: String
    let marketplace: String
    let description: String?
    let version: String?
    let isInstalled: Bool
}

struct MarketplaceRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let sourceLabel: String
    let autoUpdate: Bool
    let pluginCount: Int
    let declaredInUserSettings: Bool
    let installLocation: String
    /// `marketplace.json` 의 `metadata.version` — declared 안 되어 있으면 nil.
    let version: String?
    /// `marketplace.json` root `description` 또는 `metadata.description`.
    let description: String?
    /// `known_marketplaces.json` 의 lastUpdated — refresh 시점의 표시.
    let lastUpdated: Date
}

extension ComponentCounts {
    /// 인벤토리 행에 표시할 짧은 요약 — 0 인 항목은 생략.
    var summary: String {
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) cmd") }
        if agents > 0 { parts.append("\(agents) ag") }
        if skills > 0 { parts.append("\(skills) sk") }
        if hooks > 0 { parts.append("\(hooks) hk") }
        if mcpServers > 0 { parts.append("\(mcpServers) mcp") }
        if lspServers > 0 { parts.append("\(lspServers) lsp") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
