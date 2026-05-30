// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public struct Chunker: Sendable {
    public var targetSize: Int
    public var overlap: Int
    public var separators: [String]

    public init(
        targetSize: Int = 1000,
        overlap: Int = 150,
        separators: [String] = ["\n\n", "\n", ". ", " ", ""]
    ) {
        precondition(targetSize > 0, "chunk size must be positive")
        precondition(overlap >= 0 && overlap < targetSize, "overlap must be in [0, targetSize)")
        precondition(!separators.isEmpty, "must provide at least one separator")
        self.targetSize = targetSize
        self.overlap = overlap
        self.separators = separators
    }

    public func chunk(_ text: String) -> [String] {
        var pieces: [String] = []
        splitRecursive(text, separatorIndex: 0, into: &pieces)
        return mergePieces(pieces)
    }

    /// `separatorIndex` walks the fixed `separators` array instead of slicing
    /// a fresh `[String]` on each recursive call — identical traversal, no
    /// per-call array allocation.
    private func splitRecursive(_ text: String, separatorIndex: Int, into output: inout [String]) {
        if text.isEmpty { return }
        if text.count <= targetSize {
            output.append(text)
            return
        }
        guard separatorIndex < separators.count else {
            output.append(text)
            return
        }
        let separator = separators[separatorIndex]
        if separator.isEmpty {
            // Hard character split fallback.
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: targetSize, limitedBy: text.endIndex) ?? text.endIndex
                output.append(String(text[index..<end]))
                index = end
            }
            return
        }
        let components = text.components(separatedBy: separator)
        for (i, part) in components.enumerated() {
            let glued = i == components.count - 1 ? part : part + separator
            if glued.count <= targetSize {
                output.append(glued)
            } else {
                splitRecursive(glued, separatorIndex: separatorIndex + 1, into: &output)
            }
        }
    }

    private func mergePieces(_ pieces: [String]) -> [String] {
        var merged: [String] = []
        var current = ""
        // The accumulator grows up to ~targetSize (+overlap+one piece) before
        // being flushed; reserving avoids repeated reallocation as we append.
        // Resulting strings are byte-identical to the previous `+=` version.
        current.reserveCapacity(targetSize + overlap)
        for piece in pieces {
            if current.isEmpty {
                current = piece
                continue
            }
            if current.count + piece.count <= targetSize {
                current.append(contentsOf: piece)
            } else {
                merged.append(current)
                if overlap > 0 && current.count > overlap {
                    let start = current.index(current.endIndex, offsetBy: -overlap)
                    let tail = String(current[start...])
                    current = tail
                    current.append(contentsOf: piece)
                } else {
                    current = piece
                }
            }
        }
        if !current.isEmpty { merged.append(current) }
        return merged
    }
}
