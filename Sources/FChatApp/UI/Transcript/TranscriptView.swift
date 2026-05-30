// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

/// Chat transcript with sticky-bottom semantics implemented via inverted scroll.
///
/// The whole `ScrollView` is rotated 180°, and each row is rotated back. In the
/// flipped coordinate space the visual bottom (latest message) maps to scroll
/// offset 0 — so "stay pinned to the bottom" is just "stay at offset 0", which
/// SwiftUI's `ScrollView` does for free when content grows. No `scrollTo`
/// gymnastics, no user-vs-programmatic scroll detection, no race against
/// streaming deltas.
///
/// This is the same architecture used by iMessage, ChatGPT.app, and
/// `vellum-ai/vellum-assistant` (MIT, the pattern that inspired this port).
struct TranscriptView: View {
    let conversation: Conversation
    var failureForMessageID: MessageID? = nil
    var failureMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    /// Id of the message currently being streamed into. Non-nil only while a
    /// reply is in flight. When set, the row matching this id grows on every
    /// token delta and we measure its height so we can anchor-compensate the
    /// scroll offset when the user has scrolled away from the bottom.
    var streamingMessageID: MessageID? = nil
    /// Indices of compaction record ids whose dropped originals are currently
    /// expanded by the user. Empty by default — originals are collapsed.
    @State private var expandedCompactions: Set<UUID> = []
    /// Viewport height, captured from the ScrollView geometry. Used to give
    /// the content a `minHeight` so an under-full transcript pins to the
    /// visual top (= the flipped layout's bottom) instead of free-floating.
    @State private var viewportHeight: CGFloat = 0
    /// Scroll position binding. Used to programmatically nudge the offset when
    /// the streaming row grows beneath a user who has scrolled up.
    @State private var scrollPosition = ScrollPosition()
    /// Last-observed scroll offset (document coordinates, pre-flip). Drives
    /// the "is the user near the bottom?" gate for anchor compensation.
    @State private var contentOffsetY: CGFloat = 0
    /// Last-observed height of the streaming row. The delta against the new
    /// height is exactly how far older rows drifted down in document coords.
    @State private var streamingRowHeight: CGFloat = 0
    /// MessageID we last computed a height delta against. When the streaming
    /// id changes (new reply starts), we record the first height without
    /// compensating — there's no prior height to compute a delta from.
    @State private var lastCompensatedStreamingRowID: MessageID?

    /// Below this offset (document coords) we consider the user "at the
    /// bottom" and let SwiftUI's natural auto-follow do its job. Above it,
    /// we anchor-compensate against streaming-row growth.
    private let bottomAnchorEpsilon: CGFloat = 4

    var body: some View {
        // Render rows newest-first; the .flipped() below visually re-reverses
        // so the user sees them oldest-first with newest at the visual bottom.
        let rows = buildRows()

        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    rowView(for: row)
                        .flipped()
                }
                if conversation.messages.isEmpty {
                    EmptyChatView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                        .flipped()
                }
            }
            .padding(.vertical, DesignTokens.panelPadding)
            // Pin under-full content to the visual top (= post-flip `.bottom`)
            // so a fresh chat with one short message anchors cleanly to the
            // top of the empty area instead of floating in the middle.
            .frame(minHeight: viewportHeight, alignment: .bottom)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, h in
            viewportHeight = h
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
            contentOffsetY = y
        }
        .onChange(of: streamingMessageID) { _, newID in
            // New reply starting (or the old one ended): drop the prior
            // height baseline so we don't compute a phantom delta against a
            // dead row's last height.
            if newID != lastCompensatedStreamingRowID {
                streamingRowHeight = 0
                lastCompensatedStreamingRowID = nil
            }
        }
        .flipped()
    }

    /// Called every time the streaming row's measured height changes. When
    /// the row grew and the user has scrolled up, push the scroll offset by
    /// the same delta so the content under their eye stays anchored.
    private func compensate(newHeight: CGFloat) {
        // First observation of this row — record the baseline; can't compute
        // a delta yet.
        if lastCompensatedStreamingRowID != streamingMessageID {
            streamingRowHeight = newHeight
            lastCompensatedStreamingRowID = streamingMessageID
            return
        }

        let delta = newHeight - streamingRowHeight
        streamingRowHeight = newHeight

        // Only compensate on growth (deltas should be positive while
        // streaming text in; ignore noise / shrink).
        guard delta > 0 else { return }
        // User is at / near the bottom: SwiftUI's inverted-scroll keeps them
        // pinned for free. Don't touch the offset or we'll bounce them off.
        guard contentOffsetY > bottomAnchorEpsilon else { return }

        // Push the offset down by exactly the amount the content moved.
        // No animation: this should be invisible motion-wise, only a
        // counter-cancellation of the visible drift.
        withTransaction(Transaction(animation: nil)) {
            scrollPosition.scrollTo(y: contentOffsetY + delta)
        }
    }

    // MARK: - Row model

    /// Flat list of rows in *newest-first* order (so the ScrollView, once
    /// flipped, presents them oldest-first with newest at the visual bottom).
    private enum Row: Identifiable {
        case message(Message, contextTokens: Int?, failure: String?, retry: (() -> Void)?)
        case droppedMessage(Message)
        case compactionMarker(CompactionRecord, isExpanded: Bool)

        var id: AnyHashable {
            switch self {
            case .message(let m, _, _, _):      return AnyHashable(m.id)
            case .droppedMessage(let m):        return AnyHashable("dropped-\(m.id.rawValue)")
            case .compactionMarker(let r, _):   return AnyHashable("marker-\(r.id)")
            }
        }
    }

    private func buildRows() -> [Row] {
        let recordsByEnd: [Int: [CompactionRecord]] = Dictionary(
            grouping: conversation.compactions, by: \.toIndex
        )

        var rows: [Row] = []
        rows.reserveCapacity(conversation.messages.count + conversation.compactions.count)

        for (index, message) in conversation.messages.enumerated() {
            // A marker sits *before* the first kept message after a dropped block.
            if let records = recordsByEnd[index] {
                for record in records {
                    rows.append(.compactionMarker(record, isExpanded: expandedCompactions.contains(record.id)))
                }
            }

            let recordContainingThis = conversation.compactions.first { record in
                index >= record.fromIndex && index < record.toIndex
            }
            if let record = recordContainingThis {
                if expandedCompactions.contains(record.id) {
                    rows.append(.droppedMessage(message))
                }
                // Collapsed: skip the message; only the marker is visible.
            } else {
                rows.append(.message(
                    message,
                    contextTokens: conversation.contextTokensByMessage[message.id],
                    failure: failureForMessageID == message.id ? failureMessage : nil,
                    retry: failureForMessageID == message.id ? onRetry : nil
                ))
            }
        }

        // Reverse so the LazyVStack renders newest first; .flipped() then puts
        // them at the visual bottom in the original chronological order.
        return rows.reversed()
    }

    @ViewBuilder
    private func rowView(for row: Row) -> some View {
        switch row {
        case .message(let message, let contextTokens, let failure, let retry):
            MessageView(
                message: message,
                contextTokens: contextTokens,
                failureError: failure,
                onRetry: retry,
                streamingMessageID: streamingMessageID
            )
            .padding(.horizontal, DesignTokens.panelPadding)
            .id(message.id)
            // Only the streaming row measures itself — every other row is
            // fixed-content and would waste main-actor cycles on layout
            // callbacks for no compensation work.
            .modifier(StreamingHeightObserver(
                isActive: message.id == streamingMessageID,
                onHeight: compensate(newHeight:)
            ))

        case .droppedMessage(let message):
            MessageView(message: message)
                .opacity(0.55)
                .padding(.horizontal, DesignTokens.panelPadding)
                .id(message.id)

        case .compactionMarker(let record, let isExpanded):
            CompactionMarker(
                record: record,
                isExpanded: isExpanded,
                onToggle: {
                    if expandedCompactions.contains(record.id) {
                        expandedCompactions.remove(record.id)
                    } else {
                        expandedCompactions.insert(record.id)
                    }
                }
            )
            .padding(.horizontal, DesignTokens.panelPadding)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Flipped modifier

/// Rotates a view 180° and mirrors it horizontally so that text reads correctly
/// after a parent flip. Apply once to the ScrollView, once to each row, and the
/// rotations cancel for content while inverting the scroll axis.
extension View {
    fileprivate func flipped() -> some View {
        rotationEffect(.degrees(180))
            .scaleEffect(x: -1, y: 1, anchor: .center)
    }
}

// MARK: - Streaming row height observer

/// Reports the host view's height whenever it changes, but only when
/// `isActive` is true. Used by `TranscriptView` to drive anchor
/// compensation against the currently-streaming row's growth without
/// paying for layout measurement on every other row.
private struct StreamingHeightObserver: ViewModifier {
    let isActive: Bool
    let onHeight: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, h in
                onHeight(h)
            }
        } else {
            content
        }
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start a conversation")
                .font(.title3.weight(.semibold))
            Text("Type below to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius))
    }
}
