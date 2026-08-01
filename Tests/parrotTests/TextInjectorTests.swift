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

    func testTreatsOpaqueCustomEditorAsAmbiguousInsteadOfNonText() {
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
