import SwiftUI
import PluginCore

/// Add Marketplace 시트.
///
/// PRD §F2.2: 6개 source type 모두 단일 텍스트 필드로 — CLI 가 자동 감지.
/// `--ref` / `--auto-update` / `--path` 는 CLI 미지원 → add 후 settings.json 직접 mutation
/// 필요 (현재 구현은 add 만, ref 백필은 후속 iteration).
struct AddMarketplaceSheet: View {
    @Binding var isPresented: Bool
    let onSubmit: @MainActor (_ source: String, _ scope: PluginScope, _ sparsePaths: [String]) async -> Void

    @State private var source: String = ""
    @State private var scope: PluginScope = .user
    @State private var sparseText: String = ""
    @State private var isSubmitting: Bool = false

    var canSubmit: Bool {
        !source.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "plus.app.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Add Marketplace").font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Source").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "",
                    text: $source,
                    prompt: Text("github.com/foo/bar · https://… · /path/to/dir · npm-pkg")
                )
                .font(.body.monospaced())
                Text("CLI 가 형식에서 source type 자동 감지: github / git / url / file / directory / npm.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Scope").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $scope) {
                    Text("user").tag(PluginScope.user)
                    Text("project").tag(PluginScope.project)
                    Text("local").tag(PluginScope.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Sparse paths (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "",
                    text: $sparseText,
                    prompt: Text("monorepo subset — e.g. plugins/foo, plugins/bar")
                )
                Text("쉼표로 구분. github / git / git-subdir source 에서만 의미 있음.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button {
                    isSubmitting = true
                    Task {
                        let trimmed = source.trimmingCharacters(in: .whitespaces)
                        let sparse = sparseText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        await onSubmit(trimmed, scope, sparse)
                        isSubmitting = false
                        isPresented = false
                    }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
