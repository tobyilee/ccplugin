import SwiftUI
import AppKit

/// 메뉴바 클릭 시 표시되는 빠른 status popover.
///
/// PRD §6.4: 활성 플러그인 수 / 마켓 수 / 에러 / Open Manager 버튼.
/// 첫 표시 시 `inventory.reload()` 가 자동 트리거.
struct MenubarPopover: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.tint)
                Text("Plugin Manager")
                    .font(.headline)
                Spacer()
                if inventory.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                StatLine(
                    label: "Plugins",
                    value: "\(inventory.items.count) installed · \(inventory.enabledCount) enabled",
                    icon: "shippingbox"
                )
                StatLine(
                    label: "Marketplaces",
                    value: "\(inventory.marketplaces.count) registered",
                    icon: "storefront"
                )
                if let err = inventory.lastError {
                    StatLine(
                        label: "Error",
                        value: err,
                        icon: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
            Divider()
            HStack {
                Button {
                    Task { await inventory.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(inventory.isLoading)
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Open Manager…")
                }
                .keyboardShortcut(.defaultAction)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
                .controlSize(.small)
            }
        }
        .padding(12)
        .task {
            if inventory.items.isEmpty && inventory.lastError == nil {
                await inventory.reload()
            }
        }
    }
}

private struct StatLine: View {
    let label: String
    let value: String
    let icon: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
                .foregroundStyle(tint == .red ? tint : .primary)
        }
    }
}
