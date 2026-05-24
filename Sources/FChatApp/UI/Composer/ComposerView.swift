import SwiftUI

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.errorFill, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .bottom, spacing: 8) {
                // TextField(axis: .vertical) starts at one line and grows up
                // to lineLimit before scrolling, unlike TextEditor which is
                // multi-line from the start. Bare Return submits; Shift+Return
                // inserts a literal newline.
                TextField("Message", text: $viewModel.draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.composerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.composerCornerRadius)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .onSubmit(submitIfReady)

                Button(action: submitIfReady) {
                    Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(DesignTokens.accent.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.isStreaming && viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignTokens.panelPadding)
        .onAppear { focused = true }
    }

    private func submitIfReady() {
        if viewModel.isStreaming {
            viewModel.cancel()
            return
        }
        let trimmed = viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.send()
    }
}
