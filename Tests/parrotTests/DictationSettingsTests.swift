import CoreGraphics
import XCTest
@testable import parrot

final class DictationSettingsTests: XCTestCase {
    func testDefaultsToFnAndHold() {
        withSettings { settings in
            XCTAssertEqual(settings.shortcut, .fn)
            XCTAssertEqual(settings.learningShortcut, .learnCorrection)
            XCTAssertEqual(settings.activationMode, .hold)
            XCTAssertEqual(settings.transcriptionLanguage, .automatic)
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
            let learningShortcut = HotkeyShortcut(
                keyCode: 3,
                modifiersRawValue: (
                    CGEventFlags.maskCommand.union(.maskShift)
                ).rawValue,
                isModifierOnly: false
            )

            settings.shortcut = shortcut
            settings.learningShortcut = learningShortcut
            settings.activationMode = .toggle
            settings.transcriptionLanguage = .german

            XCTAssertEqual(settings.shortcut, shortcut)
            XCTAssertEqual(settings.learningShortcut, learningShortcut)
            XCTAssertEqual(settings.shortcut.displayName, "⇧⌘Space")
            XCTAssertEqual(settings.activationMode, .toggle)
            XCTAssertEqual(settings.transcriptionLanguage, .german)
        }
    }

    func testLanguageSelectsCompatibleModelAndDecodeOptions() {
        XCTAssertEqual(
            ModelRegistry.preferred(for: .english)?.id,
            "whisper-base.en"
        )
        XCTAssertEqual(
            ModelRegistry.preferred(for: .german)?.id,
            "whisper-large-v3-turbo-german-q5"
        )
        XCTAssertEqual(
            ModelRegistry.preferred(for: .automatic)?.id,
            "whisper-small"
        )

        let automatic = WhisperKitTranscriber.decodingOptions(for: .automatic)
        XCTAssertTrue(automatic.detectLanguage)
        XCTAssertNil(automatic.language)

        let german = WhisperKitTranscriber.decodingOptions(for: .german)
        XCTAssertFalse(german.detectLanguage)
        XCTAssertEqual(german.language, "de")
    }

    func testAutomaticLanguageRoutesOnlyConfidentEnglishAndGerman() {
        XCTAssertEqual(
            AutomaticLanguageRouter.route(
                LanguageDetection(
                    language: "en",
                    logProbabilities: ["en": log(0.92), "de": log(0.04)]
                )
            ),
            .english
        )
        XCTAssertEqual(
            AutomaticLanguageRouter.route(
                LanguageDetection(
                    language: "de",
                    logProbabilities: ["en": log(0.03), "de": log(0.94)]
                )
            ),
            .german
        )
        XCTAssertEqual(
            AutomaticLanguageRouter.route(
                LanguageDetection(
                    language: "en",
                    logProbabilities: ["en": log(0.40), "de": log(0.35)]
                )
            ),
            .german
        )
        XCTAssertEqual(
            AutomaticLanguageRouter.route(
                LanguageDetection(
                    language: "fr",
                    logProbabilities: [
                        "en": log(0.04), "de": log(0.03), "fr": log(0.90),
                    ]
                )
            ),
            .multilingualFallback
        )
    }

    func testGermanSpecialistHasPinnedDownloadMetadata() {
        let german = ModelRegistry.preferred(for: .german)
        XCTAssertEqual(german?.engine, .whisperCpp)
        XCTAssertEqual(german?.languages, ["de"])
        XCTAssertEqual(
            german?.sha256,
            "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030"
        )
        XCTAssertNotNil(german?.downloadURL)
    }

    func testAppAndStatusItemUseIndependentStableIdentity() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.pkheisig.parrot")
        XCTAssertFalse(AppIdentity.statusItemAutosaveName.contains("codex"))
        XCTAssertTrue(AppIdentity.statusItemAutosaveName.hasPrefix(AppIdentity.bundleIdentifier))
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
