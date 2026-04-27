import SwiftUI

/// Marketplaces 탭 — read + mutation (M2 actions).
///
/// PRD §F2: name, source, plugin count, autoUpdate, declared origin.
/// Actions: Refresh All / Refresh / Remove (confirm) / Toggle Auto-Update.
struct MarketplacesTab: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var search: String = ""
    @State private var pendingRemoval: MarketplaceRow? = nil
    @State private var showAddSheet: Bool = false

    var filtered: [MarketplaceRow] {
        guard !search.isEmpty else { return inventory.marketplaces }
        let needle = search.lowercased()
        return inventory.marketplaces.filter {
            $0.name.lowercased().contains(needle)
                || $0.sourceLabel.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            Table(filtered) {
                TableColumn("Marketplace") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.body.bold())
                            if !row.declaredInUserSettings {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("seed 마켓 또는 user settings 미선언 — 매니저 read-only")
                            }
                        }
                        Text(row.sourceLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        rowContextMenu(for: row)
                    }
                }
                TableColumn("Plugins") { row in
                    Text("\(row.pluginCount)")
                        .font(.caption.monospaced())
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Auto-Update") { row in
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { row.autoUpdate },
                            set: { newValue in
                                Task {
                                    await inventory.setAutoUpdate(
                                        name: row.name,
                                        autoUpdate: newValue
                                    )
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!row.declaredInUserSettings || inventory.isMutating)
                }
                .width(min: 90, ideal: 100, max: 120)
                TableColumn("") { row in
                    HStack(spacing: 4) {
                        Button {
                            Task { await inventory.refreshMarketplace(name: row.name) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh this marketplace")
                        .disabled(inventory.isMutating)

                        Button {
                            pendingRemoval = row
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove (cascade)")
                        .disabled(!row.declaredInUserSettings || inventory.isMutating)
                    }
                }
                .width(min: 70, ideal: 80, max: 100)
            }
            .searchable(text: $search, prompt: "Filter by name or source")
            footerBar
        }
        .alert(
            "Remove marketplace \(pendingRemoval?.name ?? "")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { row in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                let name = row.name
                pendingRemoval = nil
                Task { await inventory.removeMarketplace(name: name) }
            }
        } message: { row in
            Text("\(row.pluginCount) plugin(s) from this marketplace will be cascaded (uninstalled). cache 디렉토리는 orphan 으로 남음.")
        }
        .sheet(isPresented: $showAddSheet) {
            AddMarketplaceSheet(isPresented: $showAddSheet) { source, scope, sparsePaths in
                await inventory.addMarketplace(
                    source: source,
                    scope: scope,
                    sparsePaths: sparsePaths
                )
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Marketplace", systemImage: "plus.circle")
            }
            .disabled(inventory.isMutating)
            Button {
                Task { await inventory.refreshAllMarketplaces() }
            } label: {
                Label("Refresh All", systemImage: "arrow.clockwise.circle")
            }
            .disabled(inventory.isMutating)
            .help("`claude plugin marketplace update` 호출")
            Spacer()
            if inventory.isMutating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowContextMenu(for row: MarketplaceRow) -> some View {
        Button("Refresh") {
            Task { await inventory.refreshMarketplace(name: row.name) }
        }
        .disabled(inventory.isMutating)
        Button(row.autoUpdate ? "Disable Auto-Update" : "Enable Auto-Update") {
            Task {
                await inventory.setAutoUpdate(
                    name: row.name,
                    autoUpdate: !row.autoUpdate
                )
            }
        }
        .disabled(!row.declaredInUserSettings || inventory.isMutating)
        Divider()
        Button("Remove…", role: .destructive) {
            pendingRemoval = row
        }
        .disabled(!row.declaredInUserSettings || inventory.isMutating)
    }

    private var footerBar: some View {
        HStack {
            Text("\(filtered.count) of \(inventory.marketplaces.count) marketplaces")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            let autoUpdateCount = inventory.marketplaces.filter(\.autoUpdate).count
            Text("\(autoUpdateCount) auto-update enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.bar)
    }
}
