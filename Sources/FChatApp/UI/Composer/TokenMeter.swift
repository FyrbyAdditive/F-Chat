// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore
import FChatProviders

/// Subtle chip below the composer that surfaces the projected token cost
/// of the next send. Tap to open a popover with a breakdown and a manual
/// "Compact now" button.
struct TokenMeter: View {
    let projection: RequestPayloadBuilder.Projection?
    let budget: ContextBudget?
    let isCompacting: Bool
    let onCompactNow: () -> Void

    @State private var popoverShown = false

    var body: some View {
        Button {
            popoverShown = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCompacting ? "arrow.triangle.2.circlepath" : "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 11))
                    .symbolEffect(.rotate, options: .repeating, isActive: isCompacting)
                Text(labelText)
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(fillColor))
            .overlay(Capsule().stroke(Color.gray.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
            TokenMeterPopover(
                projection: projection,
                budget: budget,
                onCompactNow: {
                    popoverShown = false
                    onCompactNow()
                }
            )
            .frame(width: 320)
        }
    }

    /// Ratio used to flip the chip's colour. Denominator is the usable
    /// input budget (window minus the output reserve), not the raw window,
    /// so the chip turns red as we approach the compaction trigger — not
    /// just as we approach the theoretical maximum.
    private var ratio: Double {
        guard let projection, let budget, budget.safeInputBudget > 0 else { return 0 }
        return Double(projection.totalTokens) / Double(budget.safeInputBudget)
    }

    private var labelText: String {
        if isCompacting { return "Compacting…" }
        guard let projection, let budget else { return "—" }
        // Denominator stays as the full window so users see the honest
        // model maximum; colour and helpText explain the reserve.
        return "\(formatTokens(projection.totalTokens)) / \(formatTokens(budget.effectiveWindow))"
    }

    private var helpText: String {
        guard let projection, let budget else { return "Context usage" }
        let pct = Int((ratio * 100).rounded())
        return "\(projection.totalTokens.formatted()) tokens used of \(budget.safeInputBudget.formatted()) safe input budget (\(pct)%). Window: \(budget.effectiveWindow.formatted()), reserve: \(budget.outputReserve.formatted()). Click for details."
    }

    private var fillColor: Color {
        if isCompacting { return Color.blue.opacity(0.15) }
        switch ratio {
        case 0.8...: return Color.red.opacity(0.18)
        case 0.6...: return Color.orange.opacity(0.18)
        default: return Color.gray.opacity(0.08)
        }
    }

    private var textColor: Color {
        if isCompacting { return .primary }
        switch ratio {
        case 0.8...: return .red
        case 0.6...: return .orange
        default: return .secondary
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            let value = Double(count) / 1000
            if value >= 100 {
                return "\(Int(value))k"
            }
            return String(format: "%.1fk", value)
        }
        return "\(count)"
    }
}

struct TokenMeterPopover: View {
    let projection: RequestPayloadBuilder.Projection?
    let budget: ContextBudget?
    let onCompactNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context usage")
                .font(.headline)

            if let budget {
                LabeledRow(label: "Window", value: "\(budget.effectiveWindow.formatted()) tokens")
                LabeledRow(label: "Source", value: budget.sourceLabel)
                LabeledRow(label: "Reserved for reply", value: "\(budget.outputReserve.formatted())")
                LabeledRow(label: "Compacts when input ≥", value: "\(budget.compactionTrigger.formatted())")
            } else {
                Text("No budget detected. Pick a provider and a default model in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let p = projection {
                Divider().padding(.vertical, 4)
                Text("Next send projection")
                    .font(.subheadline.bold())
                LabeledRow(label: "Instructions", value: "\(p.systemTokens.formatted())")
                LabeledRow(label: "History", value: "\(p.historyTokens.formatted())")
                LabeledRow(label: "Tool defs", value: "\(p.toolDefinitionTokens.formatted())")
                LabeledRow(label: "Draft", value: "\(p.draftTokens.formatted())")
                LabeledRow(label: "Total", value: "\(p.totalTokens.formatted())", bold: true)
            }

            Divider().padding(.vertical, 4)
            Button(action: onCompactNow) {
                Label("Compact now", systemImage: "rectangle.compress.vertical")
            }
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var bold: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .fontWeight(bold ? .semibold : .regular)
        }
    }
}
