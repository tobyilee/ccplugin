import SwiftUI

/// Add Hook 시트 — event 선택 + matcher + command + optional timeout.
///
/// PRD §F5. matcher 는 literal string 만 (regex 객체는 미래 iteration).
struct AddHookSheet: View {
    @Binding var isPresented: Bool
    let onSubmit: @MainActor (_ event: String, _ matcher: String, _ command: String, _ timeout: Int?) async -> Void

    @State private var event: String = "PreToolUse"
    @State private var matcher: String = ""
    @State private var command: String = ""
    @State private var timeoutString: String = ""
    @State private var isSaving: Bool = false

    private static let knownEvents = [
        "PreToolUse",
        "PostToolUse",
        "SessionStart",
        "SessionEnd",
        "Stop",
        "SubagentStop",
        "Notification",
        "PreCompact",
        "UserPromptSubmit",
    ]

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Hook").font(.headline)

            Form {
                Picker("Event", selection: $event) {
                    ForEach(Self.knownEvents, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                TextField(
                    "Matcher",
                    text: $matcher,
                    prompt: Text("e.g. Bash · 비워두면 모든 호출 매칭")
                )
                TextField(
                    "Command",
                    text: $command,
                    prompt: Text("/usr/local/bin/my-hook.sh")
                )
                .font(.body.monospaced())
                TextField(
                    "Timeout (seconds, optional)",
                    text: $timeoutString,
                    prompt: Text("60")
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button {
                    isSaving = true
                    Task {
                        let timeout = Int(timeoutString.trimmingCharacters(in: .whitespaces))
                        await onSubmit(event, matcher, command, timeout)
                        isSaving = false
                        isPresented = false
                    }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
