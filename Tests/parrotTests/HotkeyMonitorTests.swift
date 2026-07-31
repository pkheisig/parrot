import CoreGraphics
import XCTest
@testable import parrot

final class HotkeyMonitorTests: XCTestCase {
    func testEscapeInitialKeyDownRequestsCancellation() {
        XCTAssertTrue(
            HotkeyMonitor.isCancelEvent(
                type: .keyDown,
                keyCode: HotkeyMonitor.escapeKeyCode,
                isRepeat: false
            )
        )
    }

    func testEscapeReleaseAndRepeatDoNotRequestCancellation() {
        XCTAssertFalse(
            HotkeyMonitor.isCancelEvent(
                type: .keyUp,
                keyCode: HotkeyMonitor.escapeKeyCode,
                isRepeat: false
            )
        )
        XCTAssertFalse(
            HotkeyMonitor.isCancelEvent(
                type: .keyDown,
                keyCode: HotkeyMonitor.escapeKeyCode,
                isRepeat: true
            )
        )
    }

    func testOtherKeysDoNotRequestCancellation() {
        XCTAssertFalse(
            HotkeyMonitor.isCancelEvent(
                type: .keyDown,
                keyCode: 49,
                isRepeat: false
            )
        )
    }
}
