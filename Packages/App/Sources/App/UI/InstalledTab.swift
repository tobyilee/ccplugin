import SwiftUI
import PluginCore

/// Installed 탭 — read + enable/disable + uninstall (M3 actions).
///
/// PRD §F1: name@market, version, scope, enabled, components 카운트.
/// Mutation: enabled toggle 은 settings.json 직접 flip (UX 우선, PRD §6.1).
/// uninstall 은 CLI bridge + 확인 다이얼로그.
struct InstalledTab: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var search: String = ""
    @State private var pendingUninstall: PluginInventoryRow? = nil

    var filtered: [PluginInventoryRow] {
        guard !search.isEmpty else { return inventory.items }
        let needle = search.lowercased()
        return inventory.items.filter {
            $0.id.lowercased().contains(needle)
                || ($0.description ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(filtered) {
                TableColumn("Plugin") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.body.bold())
                            Text("@\(row.marketplace)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let desc = row.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        rowContextMenu(for: row)
                    }
                }
                TableColumn("Version") { row in
                    Text(row.version)
                        .font(.caption.monospaced())
                }
                .width(min: 70, ideal: 90, max: 140)
                TableColumn("Scope") { row in
                    Text(row.scope.rawValue)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(scopeColor(row.scope).opacity(0.18))
                        .foregroundStyle(scopeColor(row.scope))
                        .clipShape(Capsule())
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Enabled") { row in
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { row.enabled },
                            set: { newValue in
                                Task {
                                    await inventory.setPluginEnabled(id: row.id, enabled: newValue)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!isToggleable(row) || inventory.isMutating)
                    .help(toggleHelp(row))
                }
                .width(min: 70, ideal: 80, max: 90)
                TableColumn("Components") { row in
                    Text(row.counts.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(row.counts == .zero ? .secondary : .primary)
                }
                .width(min: 130, ideal: 160, max: 220)
            }
            .searchable(text: $search, prompt: "Filter by name or description")
            footerBar
        }
        .alert(
            "Uninstall \(pendingUninstall?.id ?? "")?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            presenting: pendingUninstall
        ) { row in
            Button("Cancel", role: .cancel) {
                pendingUninstall = nil
            }
            Button("Uninstall", role: .destructive) {
                let id = row.id
                let scope = row.scope
                pendingUninstall = nil
                Task {
                    await inventory.uninstallPlugin(id: id, scope: scope, keepData: false)
                }
            }
            Button("Uninstall + keep data") {
                let id = row.id
                let scope = row.scope
                pendingUninstall = nil
                Task {
                    await inventory.uninstallPlugin(id: id, scope: scope, keepData: true)
                }
            }
        } message: { row in
            Text("scope: \(row.scope.rawValue) · `--keep-data` 미선택 시 ~/.claude/plugins/data/\(row.name)-\(row.marketplace)/ 삭제.")
        }
    }

    private var footerBar: some View {
        HStack {
            Text("\(filtered.count) of \(inventory.items.count) plugins · \(inventory.enabledCount) enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if inventory.items.contains(where: { $0.counts == .zero }) {
                Label("Some manifests missing", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("플러그인 cache 디렉토리 또는 plugin.json 누락 — components 0 으로 표시.")
            }
        }
        .padding(8)
        .background(.bar)
    }

    @ViewBuilder
    private func rowContextMenu(for row: PluginInventoryRow) -> some View {
        Button(row.enabled ? "Disable" : "Enable") {
            Task { await inventory.setPluginEnabled(id: row.id, enabled: !row.enabled) }
        }
        .disabled(!isToggleable(row) || inventory.isMutating)
        Button("Update") {
            Task { await inventory.updatePlugin(id: row.id, scope: row.scope) }
        }
        .disabled(row.scope == .managed || inventory.isMutating)
        Divider()
        Button("Uninstall…", role: .destructive) {
            pendingUninstall = row
        }
        .disabled(row.scope == .managed || inventory.isMutating)
    }

    private func isToggleable(_ row: PluginInventoryRow) -> Bool {
        // 직접 settings.json mutation 은 user-scope 에만 안전하게 적용.
        // 다른 scope 는 CLI 로 enable/disable 해야 적절한 settings.json 을 패치.
        row.scope == .user
    }

    private func toggleHelp(_ row: PluginInventoryRow) -> String {
        switch row.scope {
        case .user:    return "Toggle in user settings.json (instant)"
        case .project: return "project scope — settings.json 직접 토글 미지원 (Update 메뉴 사용)"
        case .local:   return "local scope — settings.json 직접 토글 미지원"
        case .managed: return "managed scope — disable 불가 (enterprise)"
        }
    }

    private func scopeColor(_ scope: PluginScope) -> Color {
        switch scope {
        case .user:    return .blue
        case .project: return .purple
        case .local:   return .orange
        case .managed: return .gray
        }
    }
}
