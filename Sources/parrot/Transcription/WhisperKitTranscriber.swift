import Foundation
import CoreML
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let language: TranscriptionLanguage
    private var pipeline: WhisperKit?

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage = .english
    ) {
        self.modelID = model.id
        self.model = model
        // English-only checkpoints cannot perform language detection.
        self.language = model.languages.contains("multi") ? language : .english
    }

    /// Loads the model into memory; downloads first if not already on disk, then
    /// runs one discarded inference so Core ML compilation cannot delay the
    /// user's first dictation.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        // `prewarm` loads every CoreML model twice. That reduces peak memory,
        // but turns Large models into a multi-minute startup gate. A menu-bar
        // dictation app needs one normal load and immediate input readiness.
        // The default macOS configuration specializes both encoder and decoder
        // for the Neural Engine. A wedged ANECompilerService can then block the
        // entire app indefinitely. Base models are fast enough on GPU and this
        // path loads independently of the ANE compiler service.
        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: WhisperKitModelStore.downloadBase,
            computeOptions: computeOptions,
            verbose: false,
            prewarm: false,
            load: true
        )
        let loadedPipeline = try await WhisperKit(config)
        pipeline = loadedPipeline

        let inferenceStarted = Date()
        _ = try await loadedPipeline.transcribe(
            audioArray: Self.inferenceWarmUpAudio,
            decodeOptions: Self.decodingOptions(for: language)
        )
        let inferenceElapsed = Date().timeIntervalSince(inferenceStarted)
        FileHandle.standardError.write(Data(
            String(
                format: "✓ %@ ready · inference primed %.2fs\n",
                model.id,
                inferenceElapsed
            ).utf8
        ))
    }

    /// Three seconds of discarded silence are enough to compile the mel, encoder,
    /// prefill, and decoder graphs. WhisperKit does not carry transcript state
    /// between calls, so this cannot condition the subsequent real recording.
    static let inferenceWarmUpAudio = [Float](
        repeating: 0,
        count: WhisperKit.sampleRate * 3
    )

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: Self.decodingOptions(for: language)
        )
        let raw = results.map(\.text).joined(separator: " ")
        let sanitized = Self.sanitize(raw)
        if sanitized.isEmpty, !raw.isEmpty {
            FileHandle.standardError.write(Data(
                "Whisper returned only non-speech tokens: \(raw)\n".utf8
            ))
        }
        return sanitized
    }

    func detectLanguage(_ audio: [Float]) async throws -> LanguageDetection {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }
        let result = try await pipeline.detectLangauge(audioArray: audio)
        return LanguageDetection(
            language: result.language,
            logProbabilities: result.langProbs
        )
    }

    func unload() {
        pipeline = nil
    }

    static func downloadModel(_ model: TranscriptionModel) async throws {
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        _ = try await WhisperKit.download(
            variant: whisperKitID,
            downloadBase: WhisperKitModelStore.downloadBase
        )
    }

    static func decodingOptions(for language: TranscriptionLanguage) -> DecodingOptions {
        switch language {
        case .automatic:
            return DecodingOptions(
                task: .transcribe,
                usePrefillPrompt: true,
                detectLanguage: true
            )
        case .english, .german:
            return DecodingOptions(
                task: .transcribe,
                language: language.languageCode,
                usePrefillPrompt: true,
                detectLanguage: false
            )
        }
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperKitModelStore {
    /// WhisperKit defaults to `~/Documents/huggingface`, which is protected by
    /// macOS Files and Folders privacy. A menu-bar app launched by LaunchServices
    /// can block there even though the same executable works from Terminal.
    /// Application Support belongs to Parrot and does not depend on another
    /// process having granted access to the user's Documents directory.
    static let downloadBase: URL = {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let url = root
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(Data(
                "Could not create WhisperKit model cache at \(url.path): \(error)\n".utf8
            ))
        }
        return url
    }()
}

struct LanguageDetection: Equatable {
    let language: String
    let logProbabilities: [String: Float]
}

enum AutomaticLanguageRoute: Equatable {
    case english
    case german
    case multilingualFallback
}

enum AutomaticLanguageRouter {
    /// Avoid selecting a specialist when neither English nor German has enough
    /// probability mass. Within that pair, a small German bias compensates for
    /// short German phrases that Whisper otherwise tends to label as English.
    static let minimumSupportedProbability: Float = 0.20
    static let minimumSupportedTotal: Float = 0.35
    static let germanPairThreshold: Float = 0.45

    static func route(_ detection: LanguageDetection) -> AutomaticLanguageRoute {
        let english = probability(detection.logProbabilities["en"])
        let german = probability(detection.logProbabilities["de"])
        let supportedTotal = english + german

        guard max(english, german) >= minimumSupportedProbability,
              supportedTotal >= minimumSupportedTotal
        else {
            return .multilingualFallback
        }

        let germanShare = german / supportedTotal
        return germanShare >= germanPairThreshold ? .german : .english
    }

    private static func probability(_ rawScore: Float?) -> Float {
        guard let rawScore else { return 0 }
        return rawScore <= 0 ? exp(rawScore) : rawScore
    }
}

actor TranscriptionService {
    private let detector: WhisperKitTranscriber
    private let english: WhisperKitTranscriber
    private let german: WhisperCppTranscriber
    private var language: TranscriptionLanguage
    private var languageRequest = 0
    private let explicitModel: (any Transcriber)?
    private let dictionary: CorrectionDictionaryStore

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage,
        usesExplicitModel: Bool = false,
        dictionary: CorrectionDictionaryStore? = nil
    ) {
        guard let detectorModel = ModelRegistry.preferred(for: .automatic),
              let englishModel = ModelRegistry.preferred(for: .english),
              let germanModel = ModelRegistry.preferred(for: .german)
        else {
            preconditionFailure("Required automatic-routing models are not registered")
        }
        let dictionary = dictionary ?? CorrectionDictionaryStore()
        self.dictionary = dictionary
        self.detector = WhisperKitTranscriber(
            model: detectorModel,
            language: .automatic
        )
        self.english = WhisperKitTranscriber(
            model: englishModel,
            language: .english
        )
        self.german = WhisperCppTranscriber(model: germanModel, dictionary: dictionary)
        self.language = language
        self.explicitModel = usesExplicitModel
            ? Self.makeTranscriber(
                model: model,
                language: language,
                dictionary: dictionary
            )
            : nil
    }

    func warmUp() async throws {
        if let explicitModel {
            try await explicitModel.warmUp()
            return
        }
        try await transcriber(for: language).warmUp()
        // Every app installation gets both specialists in the background.
        // The active language is usable before these downloads finish, except
        // when that specialist is itself the active selection.
        prefetchAutomaticSpecialists()
    }

    func setLanguage(_ language: TranscriptionLanguage) async throws -> String? {
        languageRequest += 1
        let request = languageRequest
        let next = transcriber(for: language)
        try await next.warmUp()
        guard request == languageRequest else { return nil }
        self.language = language
        if language == .automatic {
            prefetchAutomaticSpecialists()
            return "automatic · English/German specialists"
        }
        return next.modelID
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        let raw: String
        if let explicitModel {
            raw = try await explicitModel.transcribe(audio)
        } else {
            switch language {
            case .english:
                raw = try await english.transcribe(audio)
            case .german:
                raw = try await german.transcribe(audio)
            case .automatic:
                let detection = try await detector.detectLanguage(audio)
                let route = AutomaticLanguageRouter.route(detection)
                let rawScore = detection.logProbabilities[detection.language] ?? -.infinity
                FileHandle.standardError.write(Data(
                    "  detected \(detection.language) · logp \(rawScore) · route \(route)\n".utf8
                ))
                switch route {
                case .english:
                    raw = try await english.transcribe(audio)
                case .german:
                    raw = try await german.transcribe(audio)
                case .multilingualFallback:
                    raw = try await detector.transcribe(audio)
                }
            }
        }
        return dictionary.apply(to: raw)
    }

    private func transcriber(for language: TranscriptionLanguage) -> any Transcriber {
        switch language {
        case .automatic: detector
        case .english: english
        case .german: german
        }
    }

    private nonisolated static func makeTranscriber(
        model: TranscriptionModel,
        language: TranscriptionLanguage,
        dictionary: CorrectionDictionaryStore
    ) -> any Transcriber {
        switch model.engine {
        case .whisperKit:
            WhisperKitTranscriber(
                model: model,
                language: language
            )
        case .whisperCpp:
            WhisperCppTranscriber(model: model, dictionary: dictionary)
        }
    }

    private func prefetchAutomaticSpecialists() {
        guard let englishModel = ModelRegistry.preferred(for: .english),
              let germanModel = ModelRegistry.preferred(for: .german)
        else { return }
        Task.detached(priority: .utility) {
            do {
                try await WhisperKitTranscriber.downloadModel(englishModel)
            } catch {
                FileHandle.standardError.write(Data(
                    "English specialist prefetch failed: \(error)\n".utf8
                ))
            }
        }
        Task.detached(priority: .utility) {
            do {
                _ = try await GermanModelStore.shared.localURL(for: germanModel)
            } catch {
                FileHandle.standardError.write(Data(
                    "German specialist prefetch failed: \(error)\n".utf8
                ))
            }
        }
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
    case modelUnavailable
}
