import SwiftUI
import PluginCore

/// Diagnostics 탭 — DiagnosticsRunner 결과 표시.
///
/// PRD §F5. 가벼운 disk 검사 → 결과 리스트.
struct DiagnosticsTab: View {
    @EnvironmentObject var inventory: InventoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            if inventory.diagnostics.isEmpty {
                if inventory.isDiagnosing {
                    ProgressView("Running diagnostics…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text("No issues found")
                            .font(.callout)
                        Text("Re-run to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(inventory.diagnostics) { diag in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: iconFor(diag.severity))
                            .foregroundStyle(colorFor(diag.severity))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(diag.category.uppercased())")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(diag.message)
                                .font(.caption)
                                .lineLimit(3)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            footerBar
        }
    }

    @State private var pendingCleanup: CleanupConfirmation? = nil

    struct CleanupConfirmation: Identifiable {
        var id: String { "cleanup-\(count)" }
        let count: Int
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await inventory.runDiagnostics() }
            } label: {
                Label("Run Diagnostics", systemImage: "stethoscope")
            }
            .disabled(inventory.isDiagnosing)
            Button {
                Task {
                    let plan = await inventory.planOrphanedCacheCleanup()
                    pendingCleanup = CleanupConfirmation(count: plan.orphanedDirs.count)
                }
            } label: {
                Label("Clean Orphaned Cache", systemImage: "trash.circle")
            }
            .disabled(inventory.isMutating || inventory.isDiagnosing)
            .help("orphan cache 디렉토리 (marketplace remove 후 잔여) 제거")
            Spacer()
            if inventory.isDiagnosing || inventory.isMutating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .alert(item: $pendingCleanup) { confirm in
            Alert(
                title: Text(confirm.count == 0
                            ? "No orphaned cache directories"
                            : "Clean \(confirm.count) orphaned director(ies)?"),
                message: Text(confirm.count == 0
                              ? "Cache 가 깨끗합니다. 추가 작업 불필요."
                              : "삭제 후 복구 불가. 진행 전에 백업 권장."),
                primaryButton: .destructive(Text("Clean"), action: {
                    if confirm.count > 0 {
                        Task { _ = await inventory.cleanOrphanedCache() }
                    }
                }),
                secondaryButton: .cancel()
            )
        }
    }

    private var footerBar: some View {
        let errors = inventory.diagnostics.filter { $0.severity == .error }.count
        let warnings = inventory.diagnostics.filter { $0.severity == .warning }.count
        let infos = inventory.diagnostics.filter { $0.severity == .info }.count
        return HStack {
            Text("\(errors) errors · \(warnings) warnings · \(infos) info")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }

    private func iconFor(_ s: DiagnosticsRunner.Diagnostic.Severity) -> String {
        switch s {
        case .error:   return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle"
        }
    }

    private func colorFor(_ s: DiagnosticsRunner.Diagnostic.Severity) -> Color {
        switch s {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .blue
        }
    }
}
