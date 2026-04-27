import SwiftUI

/// Layer 3 hot-swap 안내 배너.
///
/// PRD §1.2 / §6.4: 매니저는 Layer 1+2 만 다룸 → mutation 후 Claude Code 세션에서
/// `/reload-plugins` 실행 필요. 어떤 mutation 이라도 발생하면 표시, 사용자가 "Got it" 으로 dismiss.
struct ReloadHintBanner: View {
    @Binding var visible: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Plugin changes pending")
                    .font(.callout.bold())
                Text("Run `/reload-plugins` in your Claude Code session for changes to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Got it") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    visible = false
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.16))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.yellow.opacity(0.45)),
            alignment: .bottom
        )
    }
}
