import SwiftUI
import PluginCore

/// Hooks 탭 — settings.json 의 `hooks` 블록 표시 + add/remove.
///
/// PRD §F5: matcher (regex/literal) + hooks[] (type=command, command, timeout?).
struct HooksTab: View {
    @EnvironmentObject var inventory: InventoryViewModel
    @State private var showAddSheet: Bool = false
    @State private var pendingRemoval: HookRemovalTarget? = nil

    struct HookRemovalTarget: Identifiable {
        let id: String
        let event: String
        let index: Int
        let summary: String
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            if let hooks = inventory.hooks, !hooks.isEmpty {
                List {
                    ForEach(hooks.keys.sorted(), id: \.self) { event in
                        Section(header: Text("\(event) (\(hooks[event]?.count ?? 0))")) {
                            let entries = hooks[event] ?? []
                            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                                hookRow(event: event, index: index, entry: entry)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No hooks configured")
                        .font(.callout)
                    Text("`Add Hook` 으로 PreToolUse / Stop / SessionStart 등 이벤트에 명령을 연결할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footerBar
        }
        .sheet(isPresented: $showAddSheet) {
            AddHookSheet(isPresented: $showAddSheet) { event, matcher, command, timeout in
                await inventory.addHook(
                    event: event,
                    matcher: matcher,
                    command: command,
                    timeout: timeout
                )
            }
        }
        .alert(
            "Remove hook?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { target in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                let event = target.event
                let index = target.index
                pendingRemoval = nil
                Task { await inventory.removeHook(event: event, at: index) }
            }
        } message: { target in
            Text(target.summary)
        }
    }

    private func hookRow(event: String, index: Int, entry: HookEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("matcher: \(entry.matcher?.displayText ?? "—")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                ForEach(Array(entry.hooks.enumerated()), id: \.offset) { _, cmd in
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(cmd.command)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                        if let t = cmd.timeout {
                            Text("(\(t)s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Button {
                pendingRemoval = HookRemovalTarget(
                    id: "\(event)-\(index)",
                    event: event,
                    index: index,
                    summary: "\(event)[\(index)] · matcher: \(entry.matcher?.displayText ?? "—")"
                )
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(inventory.isMutating)
        }
        .padding(.vertical, 4)
    }

    private var actionBar: some View {
        HStack {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Hook", systemImage: "plus.circle")
            }
            .disabled(inventory.isMutating)
            Spacer()
            if inventory.isMutating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerBar: some View {
        let total = (inventory.hooks ?? [:]).values.map(\.count).reduce(0, +)
        return HStack {
            Text("\(total) hooks across \(inventory.hooks?.count ?? 0) events")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }
}
