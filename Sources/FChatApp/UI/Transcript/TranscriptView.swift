import SwiftUI
import FChatCore

struct TranscriptView: View {
    let conversation: Conversation
    var failureForMessageID: MessageID? = nil
    var failureMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    @State private var scrollPosition: ScrollPosition = .init(idType: MessageID.self)
    /// Indices of compaction record ids whose dropped originals are currently
    /// expanded by the user. Empty by default — originals are collapsed.
    @State private var expandedCompactions: Set<UUID> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                content
                if conversation.messages.isEmpty {
                    EmptyChatView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(.vertical, DesignTokens.panelPadding)
        }
        .scrollPosition($scrollPosition, anchor: .bottom)
        .onChange(of: conversation.messages.last?.id) { _, newID in
            if let newID {
                scrollPosition.scrollTo(id: newID, anchor: .bottom)
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
