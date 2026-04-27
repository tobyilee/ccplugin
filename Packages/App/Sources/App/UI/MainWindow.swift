import SwiftUI

/// 풀 매니저 윈도우 — `NavigationSplitView` 기반 sidebar + detail.
///
/// PRD §6.4 / §F1·§F2: M1 read-only Inventory + Marketplaces 탭만.
struct MainWindow: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var selection: SidebarItem? = .installed

    enum SidebarItem: String, Identifiable, Hashable, CaseIterable {
        case installed
        case marketplaces
        case browse
        case userAssets
        case hooks
        case diagnostics

        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: return "Installed"
            case .marketplaces: return "Marketplaces"
            case .browse: return "Browse"
            case .userAssets: return "User Assets"
            case .hooks: return "Hooks"
            case .diagnostics: return "Diagnostics"
            }
        }
        var systemImage: String {
            switch self {
            case .installed: return "shippingbox"
            case .marketplaces: return "storefront"
            case .browse: return "magnifyingglass"
            case .userAssets: return "doc.text"
            case .hooks: return "bell.badge"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SidebarItem.installed) {
                    Label(
                        "Installed (\(inventory.items.count))",
                        systemImage: SidebarItem.installed.systemImage
                    )
                }
                NavigationLink(value: SidebarItem.marketplaces) {
                    Label(
                        "Marketplaces (\(inventory.marketplaces.count))",
                        systemImage: SidebarItem.marketplaces.systemImage
                    )
                }
                NavigationLink(value: SidebarItem.browse) {
                    Label(
                        "Browse (\(inventory.availablePlugins.count))",
                        systemImage: SidebarItem.browse.systemImage
                    )
                }
                Section("Local") {
                    NavigationLink(value: SidebarItem.userAssets) {
                        Label(
                            "User Assets (\(inventory.userAssets.count))",
                            systemImage: SidebarItem.userAssets.systemImage
                        )
                    }
                    NavigationLink(value: SidebarItem.hooks) {
                        Label(
                            "Hooks (\((inventory.hooks ?? [:]).values.map(\.count).reduce(0, +)))",
                            systemImage: SidebarItem.hooks.systemImage
                        )
                    }
                    NavigationLink(value: SidebarItem.diagnostics) {
                        Label(
                            "Diagnostics" + (inventory.diagnostics.isEmpty ? "" : " (\(inventory.diagnostics.count))"),
                            systemImage: SidebarItem.diagnostics.systemImage
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if inventory.needsReload {
                    ReloadHintBanner(visible: $inventory.needsReload)
                }
                Group {
                    switch selection {
                    case .installed:
                        InstalledTab()
                    case .marketplaces:
                        MarketplacesTab()
                    case .browse:
                        BrowseTab()
                    case .userAssets:
                        UserAssetsTab()
                    case .hooks:
                        HooksTab()
                    case .diagnostics:
                        DiagnosticsTab()
                    case nil:
                        VStack(spacing: 12) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Pick a section")
                                .font(.title2)
                            Text("Select a section in the sidebar.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await inventory.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(inventory.isLoading)
                    .help("Reload from disk (~/.claude)")
                }
                if let err = inventory.lastError {
                    ToolbarItem(placement: .status) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .navigationTitle("Plugin Manager")
        .navigationSubtitle("v\(AppInfo.version)")
        .task {
            if inventory.items.isEmpty && inventory.lastError == nil {
                await inventory.reload()
            }
        }
    }
}
