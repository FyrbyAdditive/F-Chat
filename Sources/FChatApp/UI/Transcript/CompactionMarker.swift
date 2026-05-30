// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

/// A thin gray rule with a centred label that marks where a chunk of past
/// messages was summarized into a synthetic system message. The original
/// messages are preserved in the conversation; the marker just notes the
/// boundary and lets the user toggle whether to see them dimmed in place.
struct CompactionMarker: View {
    let record: CompactionRecord
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 10))
                    Text(label)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.gray.opacity(0.08))
                )
                .overlay(
                    Capsule().stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Conversation summary so far: \(record.summary)")
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
        }
    }

    private var label: String {
        let suffix = isExpanded ? "hide originals" : "show originals"
        let count = record.messageCount
        let word = count == 1 ? "message" : "messages"
        return "\(count) earlier \(word) summarized · \(suffix)"
    }
}
