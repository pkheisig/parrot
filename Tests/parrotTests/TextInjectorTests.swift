import ApplicationServices
import XCTest
@testable import parrot

final class TextInjectorTests: XCTestCase {
    func testRecognizesEachWritableAccessibilityTextAttribute() {
        XCTAssertTrue(TextDestinationClassifier.isTextTarget(evidence(writable: true)))
    }

    func testRejectsFocusedElementWithoutWritableTextAttributes() {
        XCTAssertFalse(TextDestinationClassifier.isTextTarget(evidence(role: kAXGroupRole)))
    }

    func testRecognizesElectronTextAreaWithoutSettableValue() {
        XCTAssertTrue(TextDestinationClassifier.isTextTarget(evidence(role: kAXTextAreaRole)))
    }

    func testRecognizesTextEditorAncestorByRoleDescription() {
        XCTAssertTrue(
            TextDestinationClassifier.isTextTarget(
                evidence(role: kAXGroupRole, description: "message text editor")
            )
        )
    }

    func testRecognizesChromiumContentEditableMarkerAttributes() {
        XCTAssertTrue(
            TextDestinationClassifier.isTextTarget(
                evidence(
                    role: kAXGroupRole,
                    attributes: ["AXSelectedTextMarkerRange", kAXValueAttribute]
                )
            )
        )
    }

    func testDisabledTextControlIsRejected() {
        XCTAssertFalse(
            TextDestinationClassifier.isTextTarget(
                evidence(role: kAXTextAreaRole, enabled: false)
            )
        )
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
