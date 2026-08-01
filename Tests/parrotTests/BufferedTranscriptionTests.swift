import WhisperKit
import XCTest
@testable import parrot

final class BufferedTranscriptionTests: XCTestCase {
    func testMergesOverlappingTailWithoutRepeatingWords() {
        XCTAssertEqual(
            TranscriptMerger.merge(
                prefix: "This is the first part of the sentence.",
                suffix: "part of the sentence, followed by the ending."
            ),
            "This is the first part of the sentence. followed by the ending."
        )
    }

    func testKeepsNonOverlappingTail() {
        XCTAssertEqual(
            TranscriptMerger.merge(
                prefix: "The first sentence.",
                suffix: "A completely new sentence."
            ),
            "The first sentence. A completely new sentence."
        )
    }

    func testFullyRepeatedTailDoesNotDuplicateText() {
        XCTAssertEqual(
            TranscriptMerger.merge(
                prefix: "Parrot already transcribed this phrase.",
                suffix: "already transcribed this phrase."
            ),
            "Parrot already transcribed this phrase."
        )
    }

    func testOrdersAndDeduplicatesPublishedStreamSegments() {
        let first = TranscriptionSegment(id: 1, start: 0, end: 2, text: "First")
        let second = TranscriptionSegment(id: 2, start: 2, end: 4, text: "second")

        XCTAssertEqual(
            BufferedTranscriptAssembler.orderedSegments(
                confirmed: [second, first],
                unconfirmed: [second]
            ),
            [first, second]
        )
    }
}
