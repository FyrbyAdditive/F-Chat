import Foundation
import Observation
import FChatCore
import FChatRAG

/// Background queue that ingests dropped files into a collection one at a
/// time, reporting per-file status. UI binds against `entries` for the
/// progress list and `isProcessing` to know whether the spinner is up.
@MainActor
@Observable
final class IngestQueue {
    struct Entry: Identifiable, Hashable {
        let id: UUID
        let url: URL
        let filename: String
        let collectionID: CollectionID
        var status: Status
        enum Status: Hashable {
            case pending
            case running
            case succeeded
            case failed(String)
        }
    }

    var entries: [Entry] = []
    var isProcessing: Bool = false

    private let store: any CollectionStoreProtocol
    private var workTask: Task<Void, Never>?

    init(store: any CollectionStoreProtocol) {
        self.store = store
    }

    /// Add files to the queue and kick the worker if it isn't already running.
    /// Reentrant — new entries appended while the worker is mid-loop are
    /// picked up automatically.
    func enqueue(urls: [URL], into collectionID: CollectionID) {
        for url in urls {
            entries.append(Entry(
                id: UUID(),
                url: url,
                filename: url.lastPathComponent,
                collectionID: collectionID,
                status: .pending
            ))
        }
        startWorkerIfNeeded()
    }

    func cancelAll() {
        workTask?.cancel()
        workTask = nil
        isProcessing = false
        for i in entries.indices where entries[i].status == .running || entries[i].status == .pending {
            entries[i].status = .failed("cancelled")
        }
    }

    /// Mark every pending/running entry for this collection as cancelled.
    /// Other collections' entries keep running.
    func cancel(collectionID: CollectionID) {
        for i in entries.indices where entries[i].collectionID == collectionID
            && (entries[i].status == .pending || entries[i].status == .running) {
            entries[i].status = .failed("cancelled")
        }
        // If there's no work left at all anywhere, also kill the worker
        // so its loop exits and `isProcessing` flips off.
        if !entries.contains(where: { $0.status == .pending }) {
            workTask?.cancel()
            workTask = nil
            isProcessing = false
        }
    }

    func clearCompleted() {
        entries.removeAll { entry in
            switch entry.status {
            case .succeeded, .failed: return true
            default: return false
            }
        }
    }

    /// Drop completed/failed entries for one collection only.
    func clearCompleted(collectionID: CollectionID) {
        entries.removeAll { entry in
            guard entry.collectionID == collectionID else { return false }
            switch entry.status {
            case .succeeded, .failed: return true
            default: return false
            }
        }
    }

    /// Drop every entry — running, pending, or done — for a collection.
    /// Called when the collection itself is deleted so the progress view
    /// doesn't leak stale rows into the next collection the user opens.
    func removeAll(forCollection collectionID: CollectionID) {
        entries.removeAll { $0.collectionID == collectionID }
        if !entries.contains(where: { $0.status == .pending || $0.status == .running }) {
            workTask?.cancel()
            workTask = nil
            isProcessing = false
        }
    }

    private func startWorkerIfNeeded() {
        guard workTask == nil else { return }
        isProcessing = true
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let nextIndex = self.entries.firstIndex(where: { $0.status == .pending }) {
                if Task.isCancelled { break }
                self.entries[nextIndex].status = .running
                let entry = self.entries[nextIndex]
                do {
                    let data = try Data(contentsOf: entry.url)
                    _ = try await self.store.ingest(
                        data: data,
                        filename: entry.filename,
                        collectionID: entry.collectionID,
                        ingestor: FileIngestor(),
                        chunker: Chunker()
                    )
                    self.entries[nextIndex].status = .succeeded
                } catch {
                    self.entries[nextIndex].status = .failed(Self.describe(error))
                }
            }
            self.workTask = nil
            self.isProcessing = false
        }
    }

    static func describe(_ error: Error) -> String {
        if let p = error as? PersistentIngestError {
            switch p {
            case .parseFailure(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}
