import CoreGraphics
import XCTest
@testable import parrot

final class DictationSettingsTests: XCTestCase {
    func testDefaultsToFnAndHold() {
        withSettings { settings in
            XCTAssertEqual(settings.shortcut, .fn)
            XCTAssertEqual(settings.activationMode, .hold)
        }
    }

    func testPersistsShortcutAndActivationMode() {
        withSettings { settings in
            let shortcut = HotkeyShortcut(
                keyCode: 49,
                modifiersRawValue: (
                    CGEventFlags.maskCommand.union(.maskShift)
                ).rawValue,
                isModifierOnly: false
            )

            settings.shortcut = shortcut
            settings.activationMode = .toggle

            XCTAssertEqual(settings.shortcut, shortcut)
            XCTAssertEqual(settings.shortcut.displayName, "⇧⌘Space")
            XCTAssertEqual(settings.activationMode, .toggle)
        }
    }

    func testNamesLeftAndRightModifierShortcuts() {
        XCTAssertEqual(
            HotkeyShortcut(
                keyCode: 58,
                modifiersRawValue: CGEventFlags.maskAlternate.rawValue,
                isModifierOnly: true
            ).displayName,
            "Left Option"
        )
        XCTAssertEqual(
            HotkeyShortcut(
                keyCode: 61,
                modifiersRawValue: CGEventFlags.maskAlternate.rawValue,
                isModifierOnly: true
            ).displayName,
            "Right Option"
        )
    }

    private func withSettings(_ body: (DictationSettings) -> Void) {
        let suiteName = "com.digimata.parrot.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated user defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(DictationSettings(defaults: defaults))
    }
}
