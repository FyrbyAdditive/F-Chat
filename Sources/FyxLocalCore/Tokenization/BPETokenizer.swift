// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Generic byte-pair-encoding tokenizer driven by a vocabulary that maps
/// byte sequences to integer ranks. Matches OpenAI's tiktoken algorithm.
///
/// The encode loop is a straightforward implementation: take the input as
/// a sequence of single-byte "pieces", then repeatedly merge the adjacent
/// pair whose concatenation has the lowest rank in the vocabulary, until
/// no pair can be merged.
public final class BPETokenizer: Tokenizer, @unchecked Sendable {
    public let name: String
    public let vocabularyCount: Int

    /// Map from token bytes (as Data) to their integer rank.
    private let encoder: [Data: Int]

    public init(name: String, encoder: [Data: Int]) {
        self.name = name
        self.encoder = encoder
        self.vocabularyCount = encoder.count
    }

    public func encode(_ text: String) -> [Int] {
        var output: [Int] = []
        // Pre-tokenization: split on the OpenAI cl100k/o200k regex. This is
        // what tiktoken does and it matters for accurate counts; without it
        // we'd merge across word boundaries. We use a simplified subset
        // sufficient for budget estimation rather than perfect parity.
        for chunk in Self.preTokenize(text) {
            let bytes = Array(chunk.utf8)
            output.append(contentsOf: bpe(bytes))
        }
        return output
    }

    public func countTokens(in text: String) -> Int {
        var total = 0
        for chunk in Self.preTokenize(text) {
            let bytes = Array(chunk.utf8)
            total += bpe(bytes).count
        }
        return total
    }

    private func bpe(_ bytes: [UInt8]) -> [Int] {
        if bytes.isEmpty { return [] }
        if bytes.count == 1 {
            return [encoder[Data([bytes[0]])] ?? 0]
        }

        // Each "piece" is a contiguous slice of the input bytes. Start with
        // single-byte pieces; iteratively merge adjacent pairs whose joined
        // bytes have the lowest rank in the vocabulary.
        var pieces: [(start: Int, end: Int)] = (0..<bytes.count).map { ($0, $0 + 1) }

        while pieces.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(pieces.count - 1) {
                let merged = Data(bytes[pieces[i].start..<pieces[i + 1].end])
                if let rank = encoder[merged], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            if bestIndex < 0 { break }
            pieces[bestIndex] = (pieces[bestIndex].start, pieces[bestIndex + 1].end)
            pieces.remove(at: bestIndex + 1)
        }

        return pieces.map { piece in
            encoder[Data(bytes[piece.start..<piece.end])] ?? 0
        }
    }

    // MARK: - Pre-tokenization

    /// Roughly the tiktoken cl100k pre-tokenization regex. NSRegularExpression
    /// supports the constructs we need. We don't aim for perfect parity with
    /// the upstream Rust impl — only "close enough for budget estimation".
    /// The fallback (`.`) catches any byte we don't otherwise split.
    private static let pattern: String = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    private static let regex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }()

    static func preTokenize(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var chunks: [String] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            chunks.append(nsText.substring(with: match.range))
        }
        return chunks
    }
}

// MARK: - Vocab loaders

public enum TikTokenLoader {
    /// Parses an OpenAI `.tiktoken` file: lines of `base64(token_bytes) rank`.
    public static func loadEncoder(from data: Data) throws -> [Data: Int] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TokenizerError.invalidVocab("vocab file is not UTF-8")
        }
        var encoder: [Data: Int] = [:]
        encoder.reserveCapacity(220_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let bytes = Data(base64Encoded: String(parts[0])),
                  let rank = Int(parts[1]) else {
                throw TokenizerError.invalidVocab("malformed line: \(line)")
            }
            encoder[bytes] = rank
        }
        return encoder
    }
}

public enum TokenizerError: Error, Sendable, Equatable {
    case resourceMissing(String)
    case invalidVocab(String)
}
