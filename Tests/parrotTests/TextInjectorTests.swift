import AppKit
import ApplicationServices
import XCTest
@testable import parrot

final class TextInjectorTests: XCTestCase {
    func testRecognizesEachWritableAccessibilityTextAttribute() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(evidence(writable: true)),
            .knownText
        )
    }

    func testClassifierLeavesGenericCustomEditorAmbiguousUntilFocusInspection() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(evidence(role: kAXGroupRole)),
            .ambiguous
        )
    }

    func testRecognizesElectronTextAreaWithoutSettableValue() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(evidence(role: kAXTextAreaRole)),
            .knownText
        )
    }

    func testRecognizesTextEditorAncestorByRoleDescription() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(
                evidence(role: kAXGroupRole, description: "message text editor")
            ),
            .knownText
        )
    }

    func testRecognizesChromiumContentEditableMarkerAttributes() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(
                evidence(
                    role: kAXGroupRole,
                    attributes: ["AXSelectedTextMarkerRange", kAXValueAttribute]
                )
            ),
            .knownText
        )
    }

    func testDisabledTextControlIsRejected() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(
                evidence(role: kAXTextAreaRole, enabled: false)
            ),
            .knownNonText
        )
    }

    func testKnownNonTextControlUsesClipboardClassification() {
        XCTAssertEqual(
            TextDestinationClassifier.classify(evidence(role: kAXButtonRole)),
            .knownNonText
        )
    }

    func testCapturedTargetKeepsProcessAndAmbiguousClassification() {
        let target = TextInjector.Target(
            processIdentifier: 123,
            applicationName: "Codex",
            classification: .ambiguous
        )
        XCTAssertEqual(target.processIdentifier, 123)
        XCTAssertEqual(target.applicationName, "Codex")
        XCTAssertEqual(target.classification, .ambiguous)
    }

    func testFocusedTextClassificationsRestoreClipboardAfterTargetedPaste() {
        XCTAssertTrue(TextTargetClassification.knownText.restoresClipboardAfterTargetedPaste)
        XCTAssertTrue(TextTargetClassification.opaqueText.restoresClipboardAfterTargetedPaste)
        XCTAssertFalse(
            TextTargetClassification.knownNonText.restoresClipboardAfterTargetedPaste
        )
        XCTAssertFalse(TextTargetClassification.ambiguous.restoresClipboardAfterTargetedPaste)
    }

    func testSplitProcessEditorKeepsFocusedAccessibilityEvidence() {
        XCTAssertEqual(
            TextInjector.focusedChainClassification([.ambiguous, .knownText]),
            .knownText
        )
        XCTAssertEqual(
            TextInjector.focusedChainClassification([.ambiguous, .knownNonText]),
            .opaqueText
        )
        XCTAssertEqual(
            TextInjector.focusedChainClassification([.knownNonText, .knownNonText]),
            .knownNonText
        )
        XCTAssertEqual(TextInjector.focusedChainClassification([]), .ambiguous)
    }

    func testDeliveryPlanTargetsOnlyRunningTextOrOpaqueApplications() {
        let opaque = TextInjector.Target(
            processIdentifier: 123,
            applicationName: "Codex",
            classification: .ambiguous
        )
        let text = TextInjector.Target(
            processIdentifier: 456,
            applicationName: "Chrome",
            classification: .knownText
        )
        let opaqueText = TextInjector.Target(
            processIdentifier: 654,
            applicationName: "Word",
            classification: .opaqueText
        )
        let button = TextInjector.Target(
            processIdentifier: 789,
            applicationName: "Finder",
            classification: .knownNonText
        )

        XCTAssertEqual(
            TextInjector.deliveryPlan(for: opaque, targetIsRunning: true),
            .targetedPaste(123)
        )
        XCTAssertEqual(
            TextInjector.deliveryPlan(for: text, targetIsRunning: true),
            .targetedPaste(456)
        )
        XCTAssertEqual(
            TextInjector.deliveryPlan(for: opaqueText, targetIsRunning: true),
            .targetedPaste(654)
        )
        XCTAssertEqual(
            TextInjector.deliveryPlan(for: button, targetIsRunning: true),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInjector.deliveryPlan(for: opaque, targetIsRunning: false),
            .clipboardOnly
        )
        XCTAssertEqual(
            TextInjector.deliveryPlan(for: nil, targetIsRunning: false),
            .clipboardOnly
        )
    }

    func testDeliveryVerificationRequiresExactTextButNormalizesUnicode() {
        XCTAssertTrue(
            TextDeliveryVerifier.matches(
                transcript: "Café",
                observed: "Cafe\u{301}"
            )
        )
        XCTAssertFalse(
            TextDeliveryVerifier.matches(
                transcript: "complete transcript",
                observed: "complete"
            )
        )
        XCTAssertFalse(
            TextDeliveryVerifier.matches(
                transcript: "complete transcript",
                observed: nil
            )
        )
    }

    func testPasteboardSnapshotRestoresOnlyWhenBackupIsStillCurrent() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("parrot-test-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        XCTAssertTrue(
            snapshot.restore(
                to: pasteboard,
                ifUnchangedSince: transcriptChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        let rewrittenSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let rewrittenChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        XCTAssertTrue(
            rewrittenSnapshot.restore(
                to: pasteboard,
                ifUnchangedSince: rewrittenChangeCount,
                orStillContaining: "transcript"
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        let secondSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("another transcript", forType: .string)
        let secondTranscriptChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        XCTAssertFalse(
            secondSnapshot.restore(
                to: pasteboard,
                ifUnchangedSince: secondTranscriptChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testLazyTranscriptRecordsActualPasteboardConsumption() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("parrot-consumption-test-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let transcript = PasteboardTranscript(text: "consumed transcript")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([transcript.item]))
        XCTAssertFalse(transcript.wasConsumed)

        XCTAssertEqual(pasteboard.string(forType: .string), "consumed transcript")
        XCTAssertTrue(transcript.wasConsumed)
    }

    func testMaterializedTranscriptRemainsAvailableWithoutConsumption() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("parrot-materialize-test-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let transcript = PasteboardTranscript(text: "fallback transcript")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([transcript.item]))
        transcript.materialize()

        XCTAssertEqual(pasteboard.string(forType: .string), "fallback transcript")
    }

    private func evidence(
        role: String? = nil,
        description: String? = nil,
        attributes: Set<String> = [],
        writable: Bool = false,
        enabled: Bool? = true
    ) -> TextDestinationEvidence {
        TextDestinationEvidence(
            role: role,
            subrole: nil,
            roleDescription: description,
            attributeNames: attributes,
            hasSettableTextAttribute: writable,
            isEnabled: enabled
        )
    }
}
