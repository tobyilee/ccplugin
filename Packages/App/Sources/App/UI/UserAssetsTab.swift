import SwiftUI
import PluginCore
import AppKit

/// User Assets 탭 — `~/.claude/{skills,agents,commands}/` 의 user-owned 자산 read-only.
///
/// PRD §F4: plugin-managed 자산은 cache 하위에 있어 자연 제외.
/// CRUD (생성/편집/삭제) 는 후속 iteration. 현재는 Reveal-in-Finder 만 제공.
struct UserAssetsTab: View {
    @EnvironmentObject var inventory: InventoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            if inventory.userAssets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No user-owned assets")
                        .font(.callout)
                    Text("`~/.claude/{skills,agents,commands}/` 가 비어있음. 직접 작성 후 Refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(UserAssetReader.AssetKind.allCases, id: \.self) { kind in
                        let assets = inventory.userAssets.filter { $0.kind == kind }
                        if !assets.isEmpty {
                            Section(header: Text(sectionTitle(kind, count: assets.count))) {
                                ForEach(assets) { asset in
                                    HStack {
                                        Image(systemName: iconFor(kind))
                                            .foregroundStyle(.tint)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(asset.name).font(.body)
                                            Text(asset.path.path)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([asset.path])
                                        } label: {
                                            Image(systemName: "folder")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Reveal in Finder")
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            footerBar
        }
    }

    private var footerBar: some View {
        HStack {
            Text("\(inventory.userAssets.count) user-owned assets")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Read-only · CRUD coming in next iteration")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.bar)
    }

    private func sectionTitle(_ kind: UserAssetReader.AssetKind, count: Int) -> String {
        let name: String
        switch kind {
        case .skill:   name = "Skills"
        case .agent:   name = "Agents"
        case .command: name = "Commands"
        }
        return "\(name) (\(count))"
    }

    private func iconFor(_ kind: UserAssetReader.AssetKind) -> String {
        switch kind {
        case .skill:   return "sparkles.rectangle.stack"
        case .agent:   return "person.crop.circle"
        case .command: return "terminal"
        }
    }
}
