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
        case copiedToClipboard
    }

    /// Insert into the focused text element. Native controls expose writable
    /// attributes, while Electron/WebKit editors often expose only a semantic
    /// text role. If neither signal exists on the element or its parents,
    /// preserve the transcript on the clipboard instead of sending blind
    /// keystrokes to an unrelated window.
    static func deliver(_ text: String) -> Delivery {
        guard hasFocusedTextTarget() else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedToClipboard
        }
        inject(text)
        return .inserted
    }

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func hasFocusedTextTarget() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
              let raw
        else { return false }

        var element = unsafeBitCast(raw, to: AXUIElement.self)
        var inspectedRoles: [String] = []
        for _ in 0..<6 {
            let evidence = destinationEvidence(for: element)
            inspectedRoles.append(evidence.role ?? "unknown")
            if TextDestinationClassifier.isTextTarget(evidence) {
                return true
            }
            guard let parent = elementAttribute(
                element,
                name: kAXParentAttribute
            ) else { break }
            element = parent
        }
        FileHandle.standardError.write(Data(
            "no text target in focused AX path: \(inspectedRoles.joined(separator: " > "))\n".utf8
        ))
        return false
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

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
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

    static func isTextTarget(_ evidence: TextDestinationEvidence) -> Bool {
        guard evidence.isEnabled != false else { return false }
        if evidence.hasSettableTextAttribute { return true }
        if evidence.role.map(textRoles.contains) == true { return true }
        if evidence.subrole.map(textSubroles.contains) == true { return true }

        let description = evidence.roleDescription?.lowercased() ?? ""
        if ["text field", "text area", "text view", "search field", "editor"]
            .contains(where: description.contains) {
            return true
        }

        // Chromium contenteditable controls can identify themselves through
        // text-marker attributes even when their AX role is a generic group.
        let hasMarkerRange = evidence.attributeNames.contains("AXSelectedTextMarkerRange")
        let hasTextContent = evidence.attributeNames.contains(kAXValueAttribute)
            || evidence.attributeNames.contains("AXNumberOfCharacters")
        return hasMarkerRange && hasTextContent
    }
}
