import SwiftUI
import FChatCore

struct MessageView: View {
    let message: Message
    var contextTokens: Int? = nil
    var failureError: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            roleBadge
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.contentItems.enumerated()), id: \.offset) { _, item in
                    contentView(for: item)
                }
                if let failureError, let onRetry {
                    FailureRetryBanner(message: failureError, onRetry: onRetry)
                }
                if !metricsLine.isEmpty {
                    Text(metricsLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var metricsLine: String {
        var parts: [String] = []
        if let usage = message.usage {
            parts.append("\(usage.inputTokens) → \(usage.outputTokens) tokens")
            if let cached = usage.cachedInputTokens, cached > 0 {
                parts.append("\(cached) cached")
            }
            if let reasoning = usage.reasoningTokens, reasoning > 0 {
                parts.append("\(reasoning) reasoning")
            }
        }
        if let duration = message.generationDuration, duration > 0 {
            parts.append(String(format: "%.1fs", duration))
            if let tps = message.tokensPerSecond, tps.isFinite {
                let format = tps >= 100 ? "%.0f tok/s" : "%.1f tok/s"
                parts.append(String(format: format, tps))
            }
        }
        if let ctx = contextTokens, ctx > 0 {
            parts.append("context \(formatTokens(ctx))")
        }
        return parts.joined(separator: " · ")
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            let v = Double(count) / 1000
            return v >= 100 ? "\(Int(v))k" : String(format: "%.1fk", v)
        }
        return "\(count)"
    }

    private var roleBadge: some View {
        let symbol: String
        let bg: Color
        switch message.role {
        case .system: symbol = "gearshape.fill"; bg = .gray
        case .user: symbol = "person.fill"; bg = .blue
        case .assistant: symbol = "sparkle"; bg = .purple
        case .tool: symbol = "wrench.and.screwdriver.fill"; bg = .green
        }
        return Image(systemName: symbol)
            .foregroundStyle(.white)
            .padding(7)
            .background(bg.gradient, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func contentView(for item: MessageContent) -> some View {
        switch item {
        case .text(let text):
            if message.role == .user {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownView(source: text)
            }
        case .reasoningSummary(let text):
            ReasoningBlock(text: text)
        case .toolCall(let rec):
            ToolCallBlock(call: rec, result: nil)
        case .toolResult(let result):
            ToolResultBlock(result: result)
        case .image(let data, _):
#if canImport(AppKit)
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
            }
#endif
        case .attachment(let filename, _, _):
            Label(filename, systemImage: "paperclip")
                .padding(8)
                .background(DesignTokens.secondaryFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        }
    }
}

struct ReasoningBlock: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(DesignTokens.secondaryFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
    }
}

struct ToolCallBlock: View {
    let call: ToolCallRecord
    let result: ToolResultRecord?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Arguments")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                Text(call.name)
                    .font(.callout.bold())
                statusBadge
            }
        }
        .padding(10)
        .background(DesignTokens.secondaryFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}

struct ToolResultBlock: View {
    let result: ToolResultRecord
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(prettyJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            HStack {
                Image(systemName: result.isError ? "exclamationmark.bubble" : "tray.and.arrow.down")
                Text(result.isError ? "Tool result (error)" : "Tool result")
                    .font(.caption.bold())
                    .foregroundStyle(result.isError ? .red : .secondary)
            }
        }
        .padding(10)
        .background(result.isError ? DesignTokens.errorFill : DesignTokens.secondaryFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
    }

    private var prettyJSON: String {
        guard let data = result.outputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return result.outputJSON
        }
        return str
    }
}

struct FailureRetryBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Retry", action: onRetry)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(8)
        .background(DesignTokens.errorFill, in: RoundedRectangle(cornerRadius: 8))
    }
}
