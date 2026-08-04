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
        let english = ModelRegistry.preferred(for: .english)
        XCTAssertEqual(english?.id, ModelRegistry.preferred(for: .automatic)?.id)
        XCTAssertEqual(english?.engine, .whisperKit)
        XCTAssertTrue(english?.languages.contains("multi") == true)
        XCTAssertEqual(english?.id, "whisper-large-v3-turbo")
        XCTAssertEqual(english?.sizeMB, 1_620)
        XCTAssertEqual(ModelRegistry.find("whisper-large-v3-turbo")?.sizeMB, 1_620)
        XCTAssertEqual(ModelRegistry.find("whisper-large-v3-quantized")?.sizeMB, 626)
        XCTAssertEqual(
            ModelRegistry.find("whisper-large-v3-turbo-quantized")?.sizeMB,
            632
        )
        XCTAssertEqual(
            ModelRegistry.preferred(for: .german)?.id,
            "whisper-large-v3-turbo-german-q5"
        )

        let automatic = WhisperKitTranscriber.decodingOptions(for: .automatic)
        XCTAssertTrue(automatic.detectLanguage)
        XCTAssertNil(automatic.language)

        let german = WhisperKitTranscriber.decodingOptions(for: .german)
        XCTAssertFalse(german.detectLanguage)
        XCTAssertEqual(german.language, "de")

        let detectedGerman = WhisperKitTranscriber.decodingOptions(languageCode: "de")
        XCTAssertFalse(detectedGerman.detectLanguage)
        XCTAssertEqual(detectedGerman.language, "de")
    }

    func testProcessMemorySnapshotIncludesPhysicalFootprint() {
        guard let snapshot = ProcessMemorySnapshot.current() else {
            XCTFail("task_info should return a process memory snapshot")
            return
        }
        XCTAssertGreaterThan(snapshot.residentBytes, 0)
        XCTAssertGreaterThan(snapshot.physicalFootprintBytes, 0)
        XCTAssertTrue(snapshot.summary.contains("rss="))
        XCTAssertTrue(snapshot.summary.contains("footprint="))
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

    func testWhisperKitCacheDoesNotRequireDocumentsPermission() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        XCTAssertTrue(
            WhisperKitModelStore.downloadBase.standardizedFileURL.path
                .hasPrefix(applicationSupport.standardizedFileURL.path + "/")
        )
        XCTAssertFalse(WhisperKitModelStore.downloadBase.path.contains("/Documents/"))
    }

    func testWhisperKitInferenceWarmUpUsesThreeSecondsOfDiscardedSilence() {
        XCTAssertEqual(
            WhisperKitTranscriber.inferenceWarmUpAudio.count,
            48_000
        )
        XCTAssertTrue(
            WhisperKitTranscriber.inferenceWarmUpAudio.allSatisfy { $0 == 0 }
        )
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
