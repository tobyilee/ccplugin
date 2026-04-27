import SwiftUI
import PluginCore

/// Browse 탭 — 모든 마켓에서 사용 가능한 플러그인 검색 + install.
///
/// PRD §F3 / M3: marketplace catalog 기반 read-only 카탈로그 + Install 액션.
struct BrowseTab: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var search: String = ""
    @State private var pendingInstall: BrowsePluginRow? = nil

    var filtered: [BrowsePluginRow] {
        guard !search.isEmpty else { return inventory.availablePlugins }
        let needle = search.lowercased()
        return inventory.availablePlugins.filter {
            $0.name.lowercased().contains(needle)
                || $0.marketplace.lowercased().contains(needle)
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
                            if row.isInstalled {
                                Text("INSTALLED")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.18))
                                    .foregroundStyle(Color.green)
                                    .clipShape(Capsule())
                            }
                        }
                        if let desc = row.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
                TableColumn("Version") { row in
                    Text(row.version ?? "—").font(.caption.monospaced())
                }
                .width(min: 60, ideal: 80, max: 100)
                TableColumn("") { row in
                    Button {
                        pendingInstall = row
                    } label: {
                        Text(row.isInstalled ? "Installed" : "Install")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(row.isInstalled || inventory.isMutating)
                }
                .width(min: 80, ideal: 90, max: 110)
            }
            .searchable(text: $search, prompt: "Filter by name, marketplace, or description")
            footerBar
        }
        .sheet(item: $pendingInstall) { row in
            InstallDialog(
                pluginID: row.id,
                isPresented: Binding(
                    get: { pendingInstall != nil },
                    set: { if !$0 { pendingInstall = nil } }
                )
            ) { scope in
                await inventory.installPlugin(id: row.id, scope: scope)
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Text("\(filtered.count) of \(inventory.availablePlugins.count) plugins available")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            let installedCount = inventory.availablePlugins.filter(\.isInstalled).count
            Text("\(installedCount) already installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.bar)
    }
}
