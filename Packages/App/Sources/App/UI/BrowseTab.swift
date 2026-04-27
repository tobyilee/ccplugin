import SwiftUI
import PluginCore

/// Browse 탭 — 모든 마켓에서 사용 가능한 플러그인 검색 + install.
///
/// PRD §F3 / M3: marketplace catalog 기반 read-only 카탈로그 + Install 액션.
struct BrowseTab: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var search: String = ""
    @State private var pendingInstall: BrowsePluginRow? = nil
    @AppStorage("browseTab.viewMode") private var viewMode: ViewMode = .alphabetical
    @FocusState private var searchFocused: Bool

    enum ViewMode: String, CaseIterable, Identifiable {
        case alphabetical
        case byMarketplace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .alphabetical:  return "Alphabetical"
            case .byMarketplace: return "By Marketplace"
            }
        }
        var systemImage: String {
            switch self {
            case .alphabetical:  return "list.bullet"
            case .byMarketplace: return "square.stack.3d.up"
            }
        }
    }

    var filtered: [BrowsePluginRow] {
        guard !search.isEmpty else { return inventory.availablePlugins }
        let needle = search.lowercased()
        return inventory.availablePlugins.filter {
            $0.name.lowercased().contains(needle)
                || $0.marketplace.lowercased().contains(needle)
                || ($0.description ?? "").lowercased().contains(needle)
        }
    }

    /// 마켓별 그룹 — 마켓명 오름차순. 마켓 내부에서는 미설치 우선, 그다음 이름 오름차순.
    var groupedByMarketplace: [(marketplace: String, rows: [BrowsePluginRow])] {
        let groups = Dictionary(grouping: filtered, by: { $0.marketplace })
        return groups
            .map { entry in
                let sorted = entry.value.sorted { lhs, rhs in
                    if lhs.isInstalled != rhs.isInstalled { return !lhs.isInstalled }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return (marketplace: entry.key, rows: sorted)
            }
            .sorted { lhs, rhs in
                if lhs.marketplace.isEmpty != rhs.marketplace.isEmpty {
                    return !lhs.marketplace.isEmpty
                }
                return lhs.marketplace.localizedCaseInsensitiveCompare(rhs.marketplace) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            Group {
                switch viewMode {
                case .alphabetical:  alphabeticalTable
                case .byMarketplace: marketplaceList
                }
            }
            footerBar
        }
        .onAppear { searchFocused = true }
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

    // MARK: - Header (search + view picker)

    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "Type to filter plugins by name, marketplace, or description",
                    text: $search
                )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary, lineWidth: 1)
            )

            HStack(spacing: 8) {
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Alphabetical (Table)

    private var alphabeticalTable: some View {
        Table(filtered) {
            TableColumn("Plugin") { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.body.bold())
                        Text("@\(row.marketplace)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if row.isInstalled {
                            installedBadge
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
                installButton(for: row)
            }
            .width(min: 80, ideal: 90, max: 110)
        }
    }

    // MARK: - Grouped by marketplace (List + Section)

    private var marketplaceList: some View {
        List {
            ForEach(groupedByMarketplace, id: \.marketplace) { group in
                Section {
                    ForEach(group.rows) { row in
                        pluginRow(row)
                    }
                } header: {
                    marketplaceHeader(
                        name: group.marketplace,
                        count: group.rows.count,
                        installedCount: group.rows.filter(\.isInstalled).count,
                        version: inventory.marketplaces.first(where: { $0.name == group.marketplace })?.version
                    )
                }
            }
        }
        .listStyle(.inset)
    }

    private func marketplaceHeader(name: String, count: Int, installedCount: Int, version: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bag")
                .foregroundStyle(.secondary)
            Text(name.isEmpty ? "(no marketplace)" : name)
                .font(.headline)
            if let v = version {
                Text("v\(v)")
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text("· \(count) plugin\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if installedCount > 0 {
                Text("· \(installedCount) installed")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private func pluginRow(_ row: BrowsePluginRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.body.bold())
                    Text(row.version ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if row.isInstalled {
                        installedBadge
                    }
                }
                if let desc = row.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            installButton(for: row)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared cells

    private var installedBadge: some View {
        Text("INSTALLED")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.18))
            .foregroundStyle(Color.green)
            .clipShape(Capsule())
    }

    private func installButton(for row: BrowsePluginRow) -> some View {
        Button {
            pendingInstall = row
        } label: {
            Text(row.isInstalled ? "Installed" : "Install")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(row.isInstalled || inventory.isMutating)
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
