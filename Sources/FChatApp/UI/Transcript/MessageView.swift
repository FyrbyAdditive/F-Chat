// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

struct MessageView: View {
    let message: Message
    var contextTokens: Int? = nil
    var failureError: String? = nil
    var onRetry: (() -> Void)? = nil
    /// Id of the message currently being streamed into, if any. Used to drive
    /// live-thinking UI: the streaming row shows a "Thinking…" pill and its
    /// reasoning block auto-expands until the first text delta arrives.
    var streamingMessageID: MessageID? = nil

    /// True while the model is mid-turn on *this* message and hasn't started
    /// emitting visible text yet. Drives the pill + reasoning-block expand.
    /// Computed once at the top of `body` (see the `let` there) and passed
    /// explicitly into the row sub-views — calling it on every render of
    /// every visible row was the post-thinking-commit hot path at 70k.
    /// Iterates `reversed()` because once text streaming starts, the text
    /// item is always at the tail of `contentItems` — O(1) common case.
    private func computeIsActivelyThinking() -> Bool {
        guard message.id == streamingMessageID else { return false }
        for item in message.contentItems.reversed() {
            if case .text(let s) = item, !s.isEmpty { return false }
        }
        return true
    }

    var body: some View {
        let isActivelyThinking = computeIsActivelyThinking()
        // Pre-pair tool results with the call they belong to, so a
        // `.toolCall` row renders both halves in one combined box and the
        // matching `.toolResult` row is skipped during iteration.
        // RequestPayloadBuilder still lowers them as separate input items
        // when re-sending history — this pairing is purely visual.
        let resultsByCallID: [String: ToolResultRecord] = Dictionary(
            message.contentItems.compactMap { item -> (String, ToolResultRecord)? in
                if case .toolResult(let r) = item { return (r.callID, r) }
                return nil
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Set of call ids that DO have a preceding `.toolCall` item — those
        // results are folded into the combined box; the rest fall through
        // to the defensive standalone render.
        let pairedCallIDs: Set<String> = Set(
            message.contentItems.compactMap { item -> String? in
                if case .toolCall(let r) = item { return r.id }
                return nil
            }
        )
        HStack(alignment: .top, spacing: 12) {
            roleBadge
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 8) {
                if isActivelyThinking {
                    ThinkingPill()
                }
                ForEach(Array(message.contentItems.enumerated()), id: \.offset) { _, item in
                    contentView(
                        for: item,
                        isActivelyThinking: isActivelyThinking,
                        resultsByCallID: resultsByCallID,
                        pairedCallIDs: pairedCallIDs
                    )
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
    private func contentView(
        for item: MessageContent,
        isActivelyThinking: Bool,
        resultsByCallID: [String: ToolResultRecord],
        pairedCallIDs: Set<String>
    ) -> some View {
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
            ReasoningBlock(text: text, isActive: isActivelyThinking)
        case .toolCall(let rec):
            ToolCallResultBlock(call: rec, result: resultsByCallID[rec.id])
        case .toolResult(let result):
            // Already folded into the matching call's combined box above.
            // Defensive fallback: if no call ever appeared for this result
            // (data corruption / out-of-order arrival), render it standalone
            // so the user still sees the data.
            if pairedCallIDs.contains(result.callID) {
                EmptyView()
            } else {
                ToolCallResultBlock(call: nil, result: result)
            }
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
    var isActive: Bool = false
    /// `nil` means "follow the live-thinking state" (expanded while active,
    /// collapsed when not). The first explicit user toggle records a `Bool`
    /// here and from then on the user's choice wins for the life of this
    /// view. New messages get a fresh @State so auto behaviour returns.
    @State private var userOverride: Bool? = nil

    private var effectiveExpanded: Bool {
        userOverride ?? isActive
    }

    var body: some View {
        let binding = Binding<Bool>(
            get: { effectiveExpanded },
            set: { userOverride = $0 }
        )
        DisclosureGroup(isExpanded: binding) {
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
        .animation(.default, value: effectiveExpanded)
    }
}

/// Small pulsing pill shown at the top of the streaming-message body while
/// the model is producing reasoning content or pre-first-text. Disappears
/// the instant the first text delta arrives.
struct ThinkingPill: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            // Reuses the existing "Thinking" key. Xcode normalises trailing
            // punctuation when generating string-catalog symbols, so we
            // can't carry both "Thinking" and "Thinking…" — append the
            // ellipsis with a separate Text fragment.
            (Text("Thinking") + Text("\u{2026}"))
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DesignTokens.secondaryFill, in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// One collapsible box per tool invocation, holding both the call (args)
/// and the matching result (output) if it has arrived. Replaces what used
/// to be two stacked boxes per tool turn. The data model still stores
/// `.toolCall` and `.toolResult` as separate `MessageContent` items so
/// `RequestPayloadBuilder.messageItems(for:)` can lower them into the
/// distinct OpenAI Responses input items the wire requires — pairing is
/// purely visual, handled by `MessageView`.
struct ToolCallResultBlock: View {
    /// Optional so a stranded `.toolResult` with no matching `.toolCall`
    /// still renders defensively as a result-only box.
    let call: ToolCallRecord?
    let result: ToolResultRecord?
    @State private var expanded: Bool

    init(call: ToolCallRecord?, result: ToolResultRecord?) {
        self.call = call
        self.result = result
        // Chart results render the chart as their primary affordance —
        // start expanded so the user sees it immediately. Other tool
        // results default to collapsed to keep the transcript scan-able.
        _expanded = State(initialValue: result?.display == .chart)
    }

    /// If the result reports an error, treat the whole invocation as failed
    /// even when the call's own status field still says `.succeeded`. This
    /// keeps the visual feedback consistent regardless of which side the
    /// failure originated from.
    private var effectiveStatus: ToolStatus {
        if let result, result.isError { return .failed }
        return call?.status ?? .succeeded
    }

    private var displayName: String {
        call?.name ?? "Tool result"
    }

    /// One-line summary for the collapsed label, derived from known
    /// tool-arg shapes so common tools show the URL / query instead of raw
    /// JSON. Unknown tools fall back to a truncated args preview.
    private var collapsedSummary: String {
        guard let call,
              let data = call.argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        switch call.name {
        case "web_search", "rag_search":
            return (obj["query"] as? String) ?? ""
        case "web_fetch":
            return (obj["url"] as? String) ?? ""
        case "make_chart":
            // Just the chart type — using the user-supplied title here
            // duplicates what's already rendered inside the chart itself.
            // "make_chart  bar" / "line" / "pie" is enough context for
            // the collapsed row.
            return (obj["type"] as? String) ?? ""
        default:
            let trimmed = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "{}" || trimmed.isEmpty { return "" }
            return String(trimmed.prefix(80))
        }
    }

    /// True when the result is a chart. Charts are their own visualisation
    /// of the underlying data, so we suppress the raw-JSON arguments
    /// section, the "Result" label, and the divider — just the chart, in
    /// the same collapsible box, with no JSON noise.
    private var isChart: Bool {
        result?.display == .chart && !(result?.isError ?? false)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !isChart, let call {
                    argumentsSection(call)
                }
                if let result {
                    if !isChart, call != nil { Divider() }
                    resultSection(result)
                } else if call?.status == .running {
                    Label("Awaiting result\u{2026}", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption)
                Text(displayName)
                    .font(.callout.bold())
                let summary = collapsedSummary
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                statusBadge(for: effectiveStatus)
            }
        }
        .padding(10)
        .background(
            (effectiveStatus == .failed ? DesignTokens.errorFill : DesignTokens.secondaryFill),
            in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius)
        )
    }

    @ViewBuilder
    private func argumentsSection(_ call: ToolCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arguments")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func resultSection(_ result: ToolResultRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Charts are their own affordance — no "Result" label above
            // the chart. Errors and other tool results still get one so
            // the user has visual context for the payload below.
            if !isChart {
                Text(result.isError ? "Result (error)" : "Result")
                    .font(.caption2)
                    .foregroundStyle(result.isError ? .red : .secondary)
            }
            // Dispatch on the display hint so non-JSON-shaped results can
            // render as their own widgets. .chart → ToolChartView (Swift
            // Charts bar/line/pie). Default falls back to pretty-printed
            // JSON — same as the original behaviour.
            switch result.display {
            case .chart:
                ToolChartView(json: result.outputJSON)
            default:
                Text(Self.prettyJSON(for: result.outputJSON))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ToolStatus) -> some View {
        switch status {
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

    private static func prettyJSON(for raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
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
