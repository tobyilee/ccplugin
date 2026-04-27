import SwiftUI
import PluginCore

/// 단순 scope 선택 install 다이얼로그.
///
/// PRD §F3 / M3: dependencies closure 미리보기 + userConfig 폼은 후속 iteration.
/// userConfig 는 enable 시점 prompt 라 install dialog 에선 다루지 않음 (Q8 spike RESOLVED).
struct InstallDialog: View {
    let pluginID: String
    @Binding var isPresented: Bool
    let onInstall: @MainActor (PluginScope) async -> Void

    @State private var scope: PluginScope = .user
    @State private var isInstalling: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Install \(pluginID)").font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Installation scope").font(.caption).foregroundStyle(.secondary)
                Picker("Scope", selection: $scope) {
                    Text("user").tag(PluginScope.user)
                    Text("project").tag(PluginScope.project)
                    Text("local").tag(PluginScope.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(scopeHint(scope))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)

                Button {
                    isInstalling = true
                    Task {
                        await onInstall(scope)
                        isInstalling = false
                        isPresented = false
                    }
                } label: {
                    if isInstalling {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Install")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func scopeHint(_ scope: PluginScope) -> String {
        switch scope {
        case .user:    return "~/.claude/ — 모든 프로젝트에서 사용 가능"
        case .project: return "<cwd>/.claude/settings.json — 이 프로젝트에서만 사용 가능 (커밋 권장)"
        case .local:   return "<cwd>/.claude/settings.local.json — 이 프로젝트, 이 머신에서만"
        case .managed: return "Enterprise managed scope — 매니저로 설치 불가"
        }
    }
}
