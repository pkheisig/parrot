import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Delivers transcripts to the application captured at hotkey release. The
/// primary path stages a clipboard transaction and posts Paste directly to the
/// target PID; Unicode events remain only as a last-resort clipboard-failure
/// fallback.
enum TextInjector {
    static let generatedEventMarker: Int64 = 0x5041_5252_4F54 // "PARROT"

    enum Delivery: Equatable {
        case verifiedInserted
        case unverifiedWithClipboardBackup
        case copiedToClipboard
        case deliveryFailed
    }

    enum DeliveryPlan: Equatable {
        case clipboardOnly
        case targetedPaste(pid_t)
    }

    struct Target: Equatable, Sendable {
        let processIdentifier: pid_t
        let applicationName: String
        let classification: TextTargetClassification
    }

    /// Transactional delivery: stage the transcript on the clipboard, target
    /// Paste directly to the application captured at hotkey release, and only
    /// restore the previous clipboard after Accessibility verifies insertion.
    @MainActor
    static func deliver(
        _ text: String,
        to target: Target?,
        verificationSnapshot: FocusedTextSnapshot?
    ) async -> Delivery {
        let pasteboard = NSPasteboard.general
        let previousClipboard = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            if let target {
                inject(text, processIdentifier: target.processIdentifier)
            }
            return .deliveryFailed
        }
        let transcriptChangeCount = pasteboard.changeCount

        let targetIsRunning = target.map {
            NSRunningApplication(processIdentifier: $0.processIdentifier) != nil
        } ?? false
        let plan = deliveryPlan(for: target, targetIsRunning: targetIsRunning)
        guard case let .targetedPaste(processIdentifier) = plan,
              let target
        else {
            return .copiedToClipboard
        }

        postPaste(processIdentifier: processIdentifier)

        guard let verificationSnapshot else {
            NSLog(
                "Parrot: %@[%d] is opaque; retained clipboard backup",
                target.applicationName,
                target.processIdentifier
            )
            return .unverifiedWithClipboardBackup
        }

        // Event delivery is asynchronous. Poll briefly instead of trusting a
        // fixed delay, then restore the old clipboard only on exact evidence.
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if TextDeliveryVerifier.matches(
                transcript: text,
                observed: verificationSnapshot.deliveredInsertedText()
            ) {
                _ = previousClipboard.restore(
                    to: pasteboard,
                    ifUnchangedSince: transcriptChangeCount
                )
                return .verifiedInserted
            }
        }

        NSLog(
            "Parrot: could not verify delivery to %@[%d]; retained clipboard backup",
            target.applicationName,
            target.processIdentifier
        )
        return .unverifiedWithClipboardBackup
    }

    static func captureTarget() -> Target? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != getpid()
        else {
            return nil
        }
        return Target(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "app",
            classification: focusedTargetClassification(
                expectedProcessIdentifier: application.processIdentifier
            )
        )
    }

    static func deliveryPlan(
        for target: Target?,
        targetIsRunning: Bool
    ) -> DeliveryPlan {
        guard let target,
              targetIsRunning,
              target.classification != .knownNonText
        else { return .clipboardOnly }
        return .targetedPaste(target.processIdentifier)
    }

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String, processIdentifier: pid_t? = nil) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk, processIdentifier: processIdentifier)
            index = end
        }
    }

    private static func focusedTargetClassification(
        expectedProcessIdentifier: pid_t
    ) -> TextTargetClassification {
        let system = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
              let raw
        else {
            NSLog("Parrot: focused Accessibility element unavailable; attempting insertion")
            return .ambiguous
        }

        var element = unsafeBitCast(raw, to: AXUIElement.self)
        var focusedProcessIdentifier: pid_t = 0
        AXUIElementGetPid(element, &focusedProcessIdentifier)
        guard focusedProcessIdentifier == expectedProcessIdentifier else {
            NSLog(
                "Parrot: frontmost PID %d differs from focused AX PID %d; treating target as opaque",
                expectedProcessIdentifier,
                focusedProcessIdentifier
            )
            return .ambiguous
        }
        var inspectedRoles: [String] = []
        var focusedClassification = TextTargetClassification.ambiguous
        for depth in 0..<6 {
            let evidence = destinationEvidence(for: element)
            inspectedRoles.append(evidence.role ?? "unknown")
            let classification = TextDestinationClassifier.classify(evidence)
            if depth == 0 {
                focusedClassification = classification
            }
            if classification == .knownText {
                return .knownText
            }
            guard let parent = elementAttribute(
                element,
                name: kAXParentAttribute
            ) else { break }
            element = parent
        }
        if focusedClassification == .knownNonText {
            NSLog(
                "Parrot: non-text Accessibility target: %@",
                inspectedRoles.joined(separator: " > ")
            )
            return .knownNonText
        }
        NSLog(
            "Parrot: ambiguous Accessibility target: %@",
            inspectedRoles.joined(separator: " > ")
        )
        return .ambiguous
    }

    private static func destinationEvidence(
        for element: AXUIElement
    ) -> TextDestinationEvidence {
        var attributeNames: CFArray?
        let attributes: Set<String>
        if AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
           let names = attributeNames as? [String] {
            attributes = Set(names)
        } else {
            attributes = []
        }

        let hasSettableTextAttribute = TextDestinationClassifier.writableAttributes
            .contains { attribute in
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(
                    element,
                    attribute as CFString,
                    &settable
                ) == .success
                else { return false }
                return settable.boolValue
            }

        return TextDestinationEvidence(
            role: stringAttribute(element, name: kAXRoleAttribute),
            subrole: stringAttribute(element, name: kAXSubroleAttribute),
            roleDescription: stringAttribute(element, name: kAXRoleDescriptionAttribute),
            attributeNames: attributes,
            hasSettableTextAttribute: hasSettableTextAttribute,
            isEnabled: boolAttribute(element, name: kAXEnabledAttribute)
        )
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        name: String
    ) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &raw
        ) == .success
        else { return nil }
        return raw as? String
    }

    private static func boolAttribute(
        _ element: AXUIElement,
        name: String
    ) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &raw
        ) == .success
        else { return nil }
        return raw as? Bool
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        name: String
    ) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &raw
        ) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func postChunk(
        _ chunk: inout [UniChar],
        processIdentifier: pid_t?
    ) {
        let length = chunk.count
        guard length > 0 else { return }

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        if let processIdentifier {
            down?.postToPid(processIdentifier)
        } else {
            down?.post(tap: .cgSessionEventTap)
        }

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        if let processIdentifier {
            up?.postToPid(processIdentifier)
        } else {
            up?.post(tap: .cgSessionEventTap)
        }
    }

    private static func postPaste(processIdentifier: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        )
        down?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        down?.flags = .maskCommand
        down?.postToPid(processIdentifier)

        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        )
        up?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        up?.flags = .maskCommand
        up?.postToPid(processIdentifier)
    }
}

enum TextDeliveryVerifier {
    static func matches(transcript: String, observed: String?) -> Bool {
        guard let observed else { return false }
        return normalized(observed) == normalized(transcript)
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }
}

struct TextDestinationEvidence {
    let role: String?
    let subrole: String?
    let roleDescription: String?
    let attributeNames: Set<String>
    let hasSettableTextAttribute: Bool
    let isEnabled: Bool?
}

enum TextTargetClassification: Equatable {
    case knownText
    case knownNonText
    case ambiguous
}

enum TextDestinationClassifier {
    static let writableAttributes = [
        kAXValueAttribute,
        kAXSelectedTextAttribute,
        kAXSelectedTextRangeAttribute,
    ]

    private static let textRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        "AXTextView",
    ]

    private static let textSubroles: Set<String> = [
        kAXSearchFieldSubrole,
        kAXSecureTextFieldSubrole,
    ]

    private static let nonTextRoles: Set<String> = [
        kAXApplicationRole,
        kAXWindowRole,
        kAXButtonRole,
        kAXCheckBoxRole,
        kAXRadioButtonRole,
        kAXMenuRole,
        kAXMenuBarRole,
        kAXMenuItemRole,
        kAXStaticTextRole,
        kAXImageRole,
        "AXLink",
        kAXSliderRole,
        kAXScrollBarRole,
        kAXPopUpButtonRole,
        kAXProgressIndicatorRole,
        kAXBusyIndicatorRole,
        kAXToolbarRole,
        kAXTabGroupRole,
    ]

    static func classify(
        _ evidence: TextDestinationEvidence
    ) -> TextTargetClassification {
        if evidence.isEnabled == false { return .knownNonText }
        if evidence.hasSettableTextAttribute { return .knownText }
        if evidence.role.map(textRoles.contains) == true { return .knownText }
        if evidence.subrole.map(textSubroles.contains) == true { return .knownText }

        let description = evidence.roleDescription?.lowercased() ?? ""
        if ["text field", "text area", "text view", "search field", "editor"]
            .contains(where: description.contains) {
            return .knownText
        }

        // Chromium contenteditable controls can identify themselves through
        // text-marker attributes even when their AX role is a generic group.
        let hasMarkerRange = evidence.attributeNames.contains("AXSelectedTextMarkerRange")
        let hasTextContent = evidence.attributeNames.contains(kAXValueAttribute)
            || evidence.attributeNames.contains("AXNumberOfCharacters")
        if hasMarkerRange && hasTextContent { return .knownText }
        if evidence.role.map(nonTextRoles.contains) == true { return .knownNonText }
        return .ambiguous
    }
}
