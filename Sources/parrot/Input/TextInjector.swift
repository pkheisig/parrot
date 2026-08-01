import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    enum Delivery: Equatable {
        case inserted
        case insertedWithClipboardBackup
        case copiedToClipboard
    }

    struct Target: Equatable, Sendable {
        let processIdentifier: pid_t
        let applicationName: String
        let classification: TextTargetClassification
    }

    /// Insert into the focused text element. Native controls expose writable
    /// attributes, while Electron/WebKit editors often expose only a semantic
    /// text role. Opaque custom editors get an insertion attempt; only a
    /// positively identified non-text control uses the clipboard fallback.
    static func deliver(_ text: String, to target: Target?) -> Delivery {
        guard let target,
              NSRunningApplication(processIdentifier: target.processIdentifier) != nil
        else {
            copyToClipboard(text)
            return .copiedToClipboard
        }

        switch target.classification {
        case .knownNonText:
            copyToClipboard(text)
            return .copiedToClipboard
        case .knownText:
            inject(text, processIdentifier: target.processIdentifier)
            return .inserted
        case .ambiguous:
            // Opaque custom editors cannot be verified after delivery. Keep a
            // recoverable copy while still sending directly to the application.
            copyToClipboard(text)
            NSLog(
                "Parrot: opaque target %@[%d]; inserting with clipboard backup",
                target.applicationName,
                target.processIdentifier
            )
            inject(text, processIdentifier: target.processIdentifier)
            return .insertedWithClipboardBackup
        }
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
            classification: focusedTargetClassification()
        )
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

    private static func focusedTargetClassification() -> TextTargetClassification {
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
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        if let processIdentifier {
            down?.postToPid(processIdentifier)
        } else {
            down?.post(tap: .cgSessionEventTap)
        }

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        if let processIdentifier {
            up?.postToPid(processIdentifier)
        } else {
            up?.post(tap: .cgSessionEventTap)
        }
    }

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
