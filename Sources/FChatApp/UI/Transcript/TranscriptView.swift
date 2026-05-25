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
    /// True when streaming deltas should auto-scroll to the bottom.
    ///
    /// State machine, driven entirely by scroll-geometry deltas:
    ///
    /// - **Re-engage (false → true)**: any time current `distance ≤
    ///   bottomThreshold`. Covers the user scrolling all the way down,
    ///   content shrinking back inside the viewport, and our own
    ///   `scrollTo` landing at the bottom (idempotent).
    ///
    /// - **Disengage (true → false)**: any time `contentOffset.y`
    ///   decreases by more than `userScrollUpEpsilon`. Our own
    ///   `scrollTo(.bottom)` never moves offset backward (only forward,
    ///   toward larger offsets), so a backward delta is unambiguously
    ///   a user-initiated scroll up.
    ///
    /// - Otherwise: flag unchanged. Content growing below us with no
    ///   user input keeps `following == true`, and the next fingerprint
    ///   change will fire `scrollTo` and reseat us at the bottom.
    @State private var following: Bool = true

    /// Last observed `contentOffset.y`. Sentinel value `-1` = no prior
    /// sample (we won't run the disengage check until we have one to
    /// compare against).
    @State private var lastOffsetY: CGFloat = -1

    /// Distance (pts) from the bottom of the scroll content within which
    /// we consider the user "at the bottom" and re-engage auto-follow.
    private let bottomThreshold: CGFloat = 40
    /// Minimum backward offset delta to count as a user-initiated scroll
    /// up. Guards against floating-point jitter and any tiny system
    /// adjustments. Generous trackpad scrolls easily exceed this.
    private let userScrollUpEpsilon: CGFloat = 6

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
            // Single geometry-delta state machine for the `following`
            // flag. See the @State doc-comment above for the full case
            // table. Summary:
            //   distance ≤ threshold        → engage (always)
            //   offset moved backward       → disengage (user scrolled up)
            //   anything else               → leave flag alone
            .onScrollGeometryChange(for: ScrollSample.self, of: { geometry in
                ScrollSample(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            }, action: { _, current in
                let distance = current.contentHeight - (current.offsetY + current.containerHeight)
                if distance <= bottomThreshold {
                    // At (or past) the bottom for any reason: user scrolled
                    // down, content shrank to fit, our scrollTo landed, or
                    // it's the first sample on an empty/short chat. Engage.
                    following = true
                } else if lastOffsetY >= 0,
                          current.offsetY < lastOffsetY - userScrollUpEpsilon {
                    // Offset moved backward (up the document). Our own
                    // scrollTo only ever moves offset forward, so this can
                    // only be user-initiated. The user wants to read older
                    // content; stop yanking them on every delta.
                    following = false
                }
                // Otherwise: content grew below us (case A in the comment),
                // our scrollTo caught up (case B), or content shrank without
                // crossing threshold. In all of these `following` should
                // be unchanged.
                lastOffsetY = current.offsetY
            })
            .onChange(of: fingerprint) { _, _ in
                // Auto-follow on any content change while engaged. Default
                // value of `following` is true so the very first message in
                // a fresh chat scrolls into view even before any
                // scroll-geometry event has had a chance to fire.
                guard following else { return }
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

/// Snapshot of the scroll view geometry. Equatable so
/// `onScrollGeometryChange` can dedupe; passed as the observed value.
private struct ScrollSample: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
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
