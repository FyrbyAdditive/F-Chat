// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatRAG

@Suite("Chunker")
struct ChunkerTests {
    @Test func shortTextReturnsSinglePiece() {
        let chunker = Chunker(targetSize: 100, overlap: 10)
        let pieces = chunker.chunk("Hello world.")
        #expect(pieces == ["Hello world."])
    }

    @Test func emptyTextProducesEmpty() {
        let chunker = Chunker(targetSize: 100, overlap: 10)
        #expect(chunker.chunk("") == [])
    }

    @Test func splitsOnParagraphBoundaries() {
        let chunker = Chunker(targetSize: 30, overlap: 0)
        let text = "Paragraph one short.\n\nParagraph two also short.\n\nParagraph three is here."
        let pieces = chunker.chunk(text)
        #expect(pieces.count >= 2)
        for piece in pieces {
            #expect(piece.count <= 60) // size + overlap budget
        }
    }

    @Test func allPiecesCovertTheText() {
        let chunker = Chunker(targetSize: 40, overlap: 8)
        let text = String(repeating: "abc ", count: 80)
        let pieces = chunker.chunk(text)
        let joined = pieces.joined()
        for slice in stride(from: 0, to: text.count, by: 40) {
            let start = text.index(text.startIndex, offsetBy: slice)
            let end = text.index(start, offsetBy: 10, limitedBy: text.endIndex) ?? text.endIndex
            let probe = String(text[start..<end])
            #expect(joined.contains(probe))
        }
    }

    @Test func overlapAppliedBetweenAdjacentPieces() {
        let chunker = Chunker(targetSize: 30, overlap: 10, separators: ["", ])
        let text = String(repeating: "x", count: 90)
        let pieces = chunker.chunk(text)
        // After hard split into 30+30+30 pieces, merger appends new pieces
        // with overlap; we expect each subsequent merged piece to start with
        // some characters from the prior piece.
        guard pieces.count >= 2 else { Issue.record("expected >= 2 pieces"); return }
        let firstTail = String(pieces[0].suffix(10))
        #expect(pieces[1].hasPrefix(firstTail))
    }

    @Test(arguments: [
        (100, 0, 350, 4),
        (200, 50, 600, 3),
        (250, 25, 250, 1),
    ])
    func sizeOverlapMatrix(targetSize: Int, overlap: Int, totalLength: Int, expectedCountAtLeast: Int) {
        let chunker = Chunker(targetSize: targetSize, overlap: overlap)
        let pieces = chunker.chunk(String(repeating: "abcd", count: totalLength / 4))
        #expect(pieces.count >= expectedCountAtLeast)
        for piece in pieces {
            #expect(piece.count <= targetSize + overlap)
        }
    }
}
