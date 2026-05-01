import SwiftUI
import PluginCore

/// MCPs 탭 — 설치된 MCP 서버를 source(user / plugin) 와 함께 표시 + enable/disable/remove.
///
/// 변경 모델:
/// - **Enable / Disable**: `~/.claude.json` 의 모든 프로젝트 disable 배열에 일괄 적용.
///   (Claude Code 가 enable/disable 을 per-project 로 저장하므로 매니저가 일괄 mutation.)
/// - **Remove**: user-scope (`claude mcp add` 로 등록한 것) 만 가능. 플러그인 번들 MCP 는
///   호스트 플러그인을 uninstall 해야 한다.
struct MCPsTab: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var search: String = ""
    @State private var pendingDisable: MCP? = nil
    @State private var pendingRemove: MCP? = nil

    var filtered: [MCP] {
        guard !search.isEmpty else { return inventory.mcps }
        let needle = search.lowercased()
        return inventory.mcps.filter {
            $0.name.lowercased().contains(needle)
                || $0.sourceLabel.lowercased().contains(needle)
                || ($0.command ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            if inventory.mcps.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatchesState
            } else {
                List {
                    ForEach(filtered) { mcp in
                        mcpRow(mcp)
                    }
                }
            }
            footerBar
        }
        .alert(
            "Disable MCP everywhere?",
            isPresented: Binding(
                get: { pendingDisable != nil },
                set: { if !$0 { pendingDisable = nil } }
            ),
            presenting: pendingDisable
        ) { mcp in
            Button("Cancel", role: .cancel) { pendingDisable = nil }
            Button("Disable", role: .destructive) {
                let target = mcp
                pendingDisable = nil
                Task { await inventory.setMCPEnabled(target, enabled: false) }
            }
        } message: { mcp in
            Text("\(mcp.name) — disable in every existing project.\nClaude Code 세션 reload 후 적용됩니다.")
        }
        .alert(
            "Remove MCP?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            presenting: pendingRemove
        ) { mcp in
            Button("Cancel", role: .cancel) { pendingRemove = nil }
            Button("Remove", role: .destructive) {
                let target = mcp
                pendingRemove = nil
                Task { await inventory.removeMCP(target) }
            }
        } message: { mcp in
            Text("\(mcp.name) (User-scope) 등록을 ~/.claude.json 에서 제거합니다. 되돌리려면 다시 `claude mcp add` 가 필요합니다.")
        }
    }

    // MARK: - Rows

    private func mcpRow(_ mcp: MCP) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(mcp.name)
                        .font(.body.weight(.medium))
                    sourceBadge(mcp)
                    if !mcp.isEnabledEverywhere {
                        Text("disabled in \(mcp.disabledInProjects.count) project\(mcp.disabledInProjects.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let cmd = mcp.command {
                    let suffix = (mcp.args ?? []).joined(separator: " ")
                    Text(suffix.isEmpty ? cmd : "\(cmd) \(suffix)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { mcp.isEnabledEverywhere },
                set: { newValue in
                    if newValue {
                        Task { await inventory.setMCPEnabled(mcp, enabled: true) }
                    } else {
                        pendingDisable = mcp
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(inventory.isMutating)
            if case .user = mcp.source {
                Button {
                    pendingRemove = mcp
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(inventory.isMutating)
                .help("Remove user-scope MCP (claude mcp remove)")
            } else {
                // Plugin-bundled — 자리만 차지해 정렬 유지.
                Image(systemName: "trash")
                    .foregroundStyle(.clear)
                    .help("Plugin-bundled — uninstall the host plugin to remove")
            }
        }
        .padding(.vertical, 4)
    }

    private func sourceBadge(_ mcp: MCP) -> some View {
        let label = mcp.sourceLabel
        let color: Color = {
            switch mcp.source {
            case .user: return .blue
            case .plugin: return .purple
            }
        }()
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Bars / states

    private var actionBar: some View {
        HStack {
            TextField("Search by name, source, or command", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Spacer()
            if inventory.isMutating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No MCP servers installed")
                .font(.callout)
            Text("`claude mcp add <name> <command>` 로 user-scope MCP 를 등록하거나, MCP 가 포함된 플러그인을 설치하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No matches for “\(search)”")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerBar: some View {
        let total = inventory.mcps.count
        let userCount = inventory.mcps.filter { if case .user = $0.source { return true } else { return false } }.count
        let pluginCount = total - userCount
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(total) MCP\(total == 1 ? "" : "s") · \(userCount) user · \(pluginCount) plugin-bundled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("Disable applies to all current projects. New projects created later may start with the MCP enabled.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.bar)
    }
}
