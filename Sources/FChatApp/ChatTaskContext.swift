import Foundation
import FChatCore

/// Task-local context that scopes per-turn inputs (currently: attached RAG
/// collections) to the chat that initiated the turn.
///
/// `ChatViewModel.send` wraps the streamTask body in
/// `ChatTaskContext.$attachedCollections.withValue([...]) { ... }`. The
/// shared `RAGSearchTool` and its retriever read from this when the model
/// invokes a tool, so concurrent streams on different chats never see each
/// other's attached collections. `@TaskLocal` propagates into child tasks
/// (the chat-turn runner spawns one per tool call), so no extra plumbing
/// is needed at tool-invocation time.
enum ChatTaskContext {
    @TaskLocal static var attachedCollections: [CollectionID] = []
}
