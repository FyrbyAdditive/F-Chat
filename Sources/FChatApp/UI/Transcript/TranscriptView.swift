import SwiftUI
import FChatCore

struct TranscriptView: View {
    let conversation: Conversation
    var failureForMessageID: MessageID? = nil
    var failureMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    /// Indices of compaction record ids whose dropped originals are currently
    /// expanded by the user. Empty by default — originals are collapsed.
    @State private var expandedCompactions: Set<UUID> = []
    /// True when streaming deltas should auto-scroll the view to the
    /// bottom. Flips off only when the user actively scrolls up; flips
    /// back on when the user scrolls down to within `bottomThreshold` of
    /// the bottom (or sends a new message — handled separately).
    ///
    /// Critically this does NOT flip based on geometry alone — content
    /// growth during streaming naturally increases the distance from the
    /// bottom, and reading that as "user is scrolled up" would close the
    /// gate forever. We only react to user-initiated scrolls via
    /// `onScrollPhaseChange`.
    @State private var isAnchoredToBottom: Bool = true

    /// Latest scroll geometry, updated by `onScrollGeometryChange`. Used
    /// inside `onScrollPhaseChange` to decide whether the user's
    /// just-ended scroll left us at the bottom or somewhere above.
    @State private var latestDistanceFromBottom: CGFloat = 0

    /// Distance (pts) from the bottom of the scroll content within which
    /// we still consider the user "anchored".
    private let bottomThreshold: CGFloat = 40

    /// Stable id for the bottom sentinel; we scroll to this rather than to
    /// the last message because the sentinel is always at the literal
    /// bottom of the content, including any per-message footer + padding.
    private let bottomSentinelID = "transcript-bottom-sentinel"

    var body: some View {
        // Cheap fingerprint of the rendered transcript: any change here
        // means we should consider auto-scrolling. Captures both new-message
        // append (count change, id change) AND streaming deltas to the
        // current message (plainText length change).
        let fingerprint = "\(conversation.messages.count):"
            + "\(conversation.messages.last?.id.rawValue.uuidString ?? "-"):"
            + "\(conversation.messages.last?.plainText.count ?? 0)"

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    content
                    if conversation.messages.isEmpty {
                        EmptyChatView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                    // Invisible sentinel always at the bottom; we scroll
                    // to this rather than to the last message id so we
                    // catch the per-message footer + padding too.
                    Color.clear.frame(height: 1).id(bottomSentinelID)
                }
                .padding(.vertical, DesignTokens.panelPadding)
            }
            // Geometry handler: asymmetric flag updates.
            //
            // - false → true (RE-ENGAGE): allowed any time distance hits
            //   the threshold. During streaming, content only ever grows,
            //   so distance can only DECREASE if the user actively scrolled
            //   down. That's exactly what we want to detect to re-engage
            //   auto-follow without making the user wait for their gesture
            //   to settle.
            //
            // - true → false (DISENGAGE): NEVER from geometry alone, only
            //   from a settled user scroll (handled in onScrollPhaseChange).
            //   Otherwise content growth would race ahead of our scrollTo
            //   and close the gate forever.
            .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
            }, action: { _, distance in
                latestDistanceFromBottom = distance
                if !isAnchoredToBottom && distance <= bottomThreshold {
                    isAnchoredToBottom = true
                }
            })
            // Settled-gesture handler: only path that disengages auto-follow.
            // When a user scroll comes to rest above the threshold, the user
            // is reading something earlier and we should stop yanking them
            // back down on every delta.
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .idle && latestDistanceFromBottom > bottomThreshold {
                    isAnchoredToBottom = false
                }
            }
            .onChange(of: fingerprint) { _, _ in
                // Auto-follow on any content change, but only if we're
                // currently anchored. Defaults to true so the very first
                // message in a fresh chat scrolls into view even before
                // any scroll-geometry event has fired.
                guard isAnchoredToBottom else { return }
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
            .onAppear {
                // First paint of an existing chat: jump to the bottom so
                // we open at the latest message rather than the top.
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
        }
    }

    /// Walks the message list and intersperses CompactionMarkers wherever
    /// a record's `toIndex` matches the current position. Dropped messages
    /// (those inside `fromIndex..<toIndex`) are shown dimmed when the
    /// marker is expanded, hidden when collapsed.
    @ViewBuilder
    private var content: some View {
        // Build a quick lookup: at index N, are there any compaction(s)
        // whose dropped block ends here? If so, render the marker before
        // the message at N.
        let recordsByEnd: [Int: [CompactionRecord]] = Dictionary(
            grouping: conversation.compactions, by: \.toIndex
        )

        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
            // Marker between drop and keep regions.
            if let records = recordsByEnd[index] {
                ForEach(records) { record in
                    CompactionMarker(
                        record: record,
                        isExpanded: expandedCompactions.contains(record.id),
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

            let inDropped = conversation.compactions.contains { record in
                index >= record.fromIndex && index < record.toIndex
            }
            let recordContainingThis = conversation.compactions.first { record in
                index >= record.fromIndex && index < record.toIndex
            }
            let isExpanded = recordContainingThis.map { expandedCompactions.contains($0.id) } ?? false

            if inDropped {
                if isExpanded {
                    MessageView(message: message)
                        .opacity(0.55)
                        .padding(.horizontal, DesignTokens.panelPadding)
                        .id(message.id)
                }
                // Collapsed: hide the message entirely; the marker is the only
                // affordance.
            } else {
                MessageView(
                    message: message,
                    contextTokens: conversation.contextTokensByMessage[message.id],
                    failureError: failureForMessageID == message.id ? failureMessage : nil,
                    onRetry: failureForMessageID == message.id ? onRetry : nil
                )
                .padding(.horizontal, DesignTokens.panelPadding)
                .id(message.id)
            }
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
