import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

enum TextDeliveryFormatter {
    /// Keep successive dictation segments naturally separated while preserving
    /// any whitespace the recognizer already supplied.
    static func withTrailingSpace(_ text: String) -> String {
        guard let last = text.last else { return text }
        return last.isWhitespace ? text : text + " "
    }
}

/// Delivers transcripts to the application captured at hotkey release. The
/// primary path stages a clipboard transaction and posts Paste directly to the
/// target PID; Unicode events remain only as a last-resort clipboard-failure
/// fallback.
enum TextInjector {
    static let generatedEventMarker: Int64 = 0x5041_5252_4F54 // "PARROT"
    private static let logger = Logger(
        subsystem: "com.pkheisig.parrot",
        category: "delivery"
    )

    enum Delivery: Equatable {
        case verifiedInserted
        case insertedIntoTextTarget
        case unverifiedWithClipboardBackup
        case copiedToClipboard
        case deliveryFailed

        var testDescription: String {
            switch self {
            case .verifiedInserted: "verified-inserted"
            case .insertedIntoTextTarget: "consumed-and-inserted"
            case .unverifiedWithClipboardBackup: "unverified-clipboard-retained"
            case .copiedToClipboard: "clipboard-only"
            case .deliveryFailed: "delivery-failed"
            }
        }
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
        let stagedTranscript = PasteboardTranscript(text: text)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([stagedTranscript.item]) else {
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
            stagedTranscript.materialize()
            return .copiedToClipboard
        }

        postPaste(processIdentifier: processIdentifier)

        // Event delivery is asynchronous. Poll briefly instead of trusting a
        // fixed delay, then restore the old clipboard only on exact evidence.
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if let verificationSnapshot,
               TextDeliveryVerifier.matches(
                transcript: text,
                observed: verificationSnapshot.deliveredInsertedText()
            ) {
                let restored = previousClipboard.restore(
                    to: pasteboard,
                    ifUnchangedSince: transcriptChangeCount,
                    orStillContaining: text
                )
                logger.notice(
                    "Exact insertion verified; clipboard restored: \(restored, privacy: .public)"
                )
                return .verifiedInserted
            }
        }

        // Some Electron and document editors expose a focused text surface but
        // deliberately hide its value from Accessibility. The focused text
        // classification is still positive destination evidence, so do not
        // turn the temporary pasteboard staging value into a permanent copy.
        if target.classification.restoresClipboardAfterTargetedPaste {
            let restored = previousClipboard.restore(
                to: pasteboard,
                ifUnchangedSince: transcriptChangeCount,
                orStillContaining: text
            )
            logger.notice(
                "Focused \(target.classification.logLabel, privacy: .public) target; clipboard restored: \(restored, privacy: .public)"
            )
            return .insertedIntoTextTarget
        }

        // Accessibility-opaque editors such as Codex cannot expose their
        // focused value or even a stable editor role. A lazy pasteboard data
        // provider gives us a direct receipt when their Paste handler requests
        // the transcript. That is stronger evidence than application identity
        // or timing and avoids retaining a redundant clipboard copy.
        if stagedTranscript.wasConsumed {
            let restored = previousClipboard.restore(
                to: pasteboard,
                ifUnchangedSince: transcriptChangeCount,
                orStillContaining: text
            )
            logger.notice(
                "Unknown target consumed staged transcript; clipboard restored: \(restored, privacy: .public)"
            )
            return .insertedIntoTextTarget
        }

        stagedTranscript.materialize()
        logger.notice("Unknown target; transcript retained on clipboard")
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
        if focusedProcessIdentifier != expectedProcessIdentifier {
            NSLog(
                "Parrot: frontmost PID %d differs from focused AX PID %d; inspecting focused AX roles",
                expectedProcessIdentifier,
                focusedProcessIdentifier
            )
        }
        var evidenceChain: [(role: String, classification: TextTargetClassification)] = []
        for _ in 0..<6 {
            let evidence = destinationEvidence(for: element)
            let classification = TextDestinationClassifier.classify(evidence)
            evidenceChain.append((evidence.role ?? "unknown", classification))
            guard let parent = elementAttribute(
                element,
                name: kAXParentAttribute
            ) else { break }
            element = parent
        }
        let classification = focusedChainClassification(
            evidenceChain.map(\.classification)
        )
        let inspectedRoles = evidenceChain.map(\.role)
        if classification == .knownText {
            return .knownText
        }
        if classification == .knownNonText {
            NSLog(
                "Parrot: non-text Accessibility target: %@",
                inspectedRoles.joined(separator: " > ")
            )
            return .knownNonText
        }
        NSLog(
            "Parrot: opaque focused text candidate: %@",
            inspectedRoles.joined(separator: " > ")
        )
        return .opaqueText
    }

    /// A renderer/helper PID mismatch is normal in split-process editors such
    /// as Electron and must not erase the focused element's role evidence.
    static func focusedChainClassification(
        _ classifications: [TextTargetClassification]
    ) -> TextTargetClassification {
        guard let focused = classifications.first else { return .ambiguous }
        if classifications.contains(.knownText) { return .knownText }
        if focused == .knownNonText { return .knownNonText }
        return .opaqueText
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

/// A lazy pasteboard item that records whether the destination's Paste handler
/// actually requested the staged transcript. Materializing before a clipboard
/// fallback keeps the string self-contained after the delivery call returns.
final class PasteboardTranscript: NSObject, NSPasteboardItemDataProvider {
    let item = NSPasteboardItem()

    private let text: String
    private let lock = NSLock()
    private var consumed = false

    init(text: String) {
        self.text = text
        super.init()
        item.setDataProvider(self, forTypes: [.string])
    }

    var wasConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return consumed
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        consumed = true
        lock.unlock()
        item.setString(text, forType: type)
    }

    func materialize() {
        item.setString(text, forType: .string)
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
    case opaqueText
    case knownNonText
    case ambiguous

    var restoresClipboardAfterTargetedPaste: Bool {
        self == .knownText || self == .opaqueText
    }

    var logLabel: String {
        switch self {
        case .knownText: "text"
        case .opaqueText: "opaque-text"
        case .knownNonText: "non-text"
        case .ambiguous: "unknown"
        }
    }
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
