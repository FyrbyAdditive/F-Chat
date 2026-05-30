// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

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
    private let ingestor: FileIngestor
    private var workTask: Task<Void, Never>?

    /// File extensions the ingestor knows how to parse. Used by the UI's
    /// folder-walk to pre-filter recursively-collected files.
    var supportedExtensions: Set<String> { ingestor.supportedExtensions }

    init(store: any CollectionStoreProtocol, ingestor: FileIngestor = FileIngestor()) {
        self.store = store
        self.ingestor = ingestor
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
                        ingestor: self.ingestor,
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

/// Expand a list of URLs that may include folders into a flat list of
/// file URLs ready to enqueue. Folders are walked recursively; hidden
/// files (`.git`, `.DS_Store`, dotfiles) are skipped; files whose
/// extension isn't recognised by `supportedExtensions` are skipped; files
/// larger than `maxBytes` are skipped (default 16 MB — a single ingest of
/// a 100 MB binary would otherwise stall the queue and blow embedding
/// budgets).
///
/// Returns the expanded URL list plus a count of files that were skipped
/// (so the caller can surface "imported 42 of 187 files" without losing
/// the user's trust).
public struct IngestFolderExpander {
    public var supportedExtensions: Set<String>
    public var maxBytes: Int
    public var skipHidden: Bool

    public init(
        supportedExtensions: Set<String>,
        maxBytes: Int = 16 * 1024 * 1024,
        skipHidden: Bool = true
    ) {
        self.supportedExtensions = supportedExtensions
        self.maxBytes = maxBytes
        self.skipHidden = skipHidden
    }

    public struct Result {
        public var urls: [URL]
        public var skippedHidden: Int
        public var skippedUnknownType: Int
        public var skippedTooBig: Int
    }

    public func expand(_ urls: [URL]) -> Result {
        var collected: [URL] = []
        var skippedHidden = 0
        var skippedUnknown = 0
        var skippedTooBig = 0
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: skipHidden ? [.skipsHiddenFiles] : []
                ) else { continue }
                for case let fileURL as URL in walker {
                    let (kept, reason) = consider(fileURL, fm: fm)
                    if kept {
                        collected.append(fileURL)
                    } else {
                        switch reason {
                        case .hidden: skippedHidden += 1
                        case .unknownType: skippedUnknown += 1
                        case .tooBig: skippedTooBig += 1
                        case .notRegularFile: break
                        }
                    }
                }
            } else {
                let (kept, reason) = consider(url, fm: fm)
                if kept {
                    collected.append(url)
                } else {
                    switch reason {
                    case .hidden: skippedHidden += 1
                    case .unknownType: skippedUnknown += 1
                    case .tooBig: skippedTooBig += 1
                    case .notRegularFile: break
                    }
                }
            }
        }
        return Result(
            urls: collected,
            skippedHidden: skippedHidden,
            skippedUnknownType: skippedUnknown,
            skippedTooBig: skippedTooBig
        )
    }

    private enum SkipReason { case hidden, unknownType, tooBig, notRegularFile }

    private func consider(_ url: URL, fm: FileManager) -> (kept: Bool, reason: SkipReason) {
        if skipHidden && url.lastPathComponent.hasPrefix(".") {
            return (false, .hidden)
        }
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return (false, .unknownType)
        }
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) {
            if values.isRegularFile != true { return (false, .notRegularFile) }
            if let size = values.fileSize, size > maxBytes { return (false, .tooBig) }
        }
        return (true, .hidden) // reason unused on the success branch
    }
}
