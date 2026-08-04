import Foundation
import CoreML
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let defaultLanguage: TranscriptionLanguage
    private var pipeline: WhisperKit?
    private var loadTask: Task<Void, Error>?

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage = .english
    ) {
        self.modelID = model.id
        self.model = model
        // English-only checkpoints cannot perform language detection.
        self.defaultLanguage = model.languages.contains("multi") ? language : .english
    }

    /// Loads the model into memory; downloads first if not already on disk, then
    /// runs one discarded inference so Core ML compilation cannot delay the
    /// user's first dictation.
    func warmUp() async throws {
        if pipeline != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        let loadTask = Task { [self] in
            try await loadPipeline()
        }
        self.loadTask = loadTask
        do {
            try await loadTask.value
            self.loadTask = nil
        } catch {
            self.loadTask = nil
            throw error
        }
    }

    private func loadPipeline() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        let memory = MemoryPeakTracker(label: "load \(model.id)")
        defer { memory.logFinish() }
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
            decodeOptions: Self.decodingOptions(for: defaultLanguage)
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
        try await transcribe(audio, languageCode: defaultLanguage.languageCode)
    }

    /// Transcribes with a caller-selected language on the shared multilingual
    /// pipeline. Automatic routing uses this to detect and transcribe with one
    /// loaded model instead of keeping a separate detector resident.
    func transcribe(_ audio: [Float], languageCode: String?) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let memory = MemoryPeakTracker(label: "transcribe \(model.id)")
        defer { memory.logFinish() }
        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: Self.decodingOptions(languageCode: languageCode)
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
        let memory = MemoryPeakTracker(label: "detect (model.id)")
        defer { memory.logFinish() }
        let result = try await pipeline.detectLangauge(audioArray: audio)
        return LanguageDetection(
            language: result.language,
            logProbabilities: result.langProbs
        )
    }

    func isLoaded() -> Bool {
        pipeline != nil
    }

    func unload() async {
        guard let loadedPipeline = pipeline else { return }
        // WhisperKit exposes an explicit lifecycle operation. Calling it
        // before dropping the pipeline releases Core ML model weights now,
        // rather than waiting for ARC/deinitialization to unwind later.
        await loadedPipeline.unloadModels()
        pipeline = nil
        RuntimeMemoryLog.write("unloaded \(model.id)")
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
        Self.decodingOptions(
            languageCode: language.languageCode,
            detectLanguage: language == .automatic
        )
    }

    static func decodingOptions(
        languageCode: String?,
        detectLanguage: Bool? = nil
    ) -> DecodingOptions {
        let shouldDetect = detectLanguage ?? (languageCode == nil)
        return DecodingOptions(
            task: .transcribe,
            language: languageCode,
            usePrefillPrompt: true,
            detectLanguage: shouldDetect
        )
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
    /// Automatic and English share one multilingual model. Language detection
    /// and the final decode are separate calls, but they use the same loaded
    /// pipeline so Automatic does not keep a detector beside a Large model.
    private let multilingual: WhisperKitTranscriber
    private let german: WhisperCppTranscriber
    private var language: TranscriptionLanguage
    private var languageRequest = 0
    private let explicitModel: (any Transcriber)?
    private let dictionary: CorrectionDictionaryStore
    private var activeTranscriptions = 0
    private var activeLoads = 0
    private var idleEvictionTask: Task<Void, Never>?
    private var cleanupRequested = false
    private var memoryPressurePending = false

    /// Keeping a model hot for a short idle window makes repeated dictation
    /// responsive without retaining hundreds of megabytes indefinitely.
    static let idleEvictionNanoseconds: UInt64 = 60 * 1_000_000_000

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage,
        usesExplicitModel: Bool = false,
        dictionary: CorrectionDictionaryStore? = nil
    ) {
        guard let multilingualModel = ModelRegistry.preferred(for: .automatic),
              let germanModel = ModelRegistry.preferred(for: .german)
        else {
            preconditionFailure("Required automatic-routing models are not registered")
        }
        let dictionary = dictionary ?? CorrectionDictionaryStore()
        self.dictionary = dictionary
        self.multilingual = WhisperKitTranscriber(
            model: multilingualModel,
            language: .automatic
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
        cancelIdleEviction()
        activeLoads += 1
        do {
            if let explicitModel {
                try await explicitModel.warmUp()
                await finishLoad()
                return
            }
            try await transcriber(for: language).warmUp()
            // This only downloads the optional explicit German specialist. It
            // is not loaded into memory and never competes with the active model.
            if language != .german {
                prefetchGermanSpecialist()
            }
            await finishLoad()
        } catch {
            activeLoads = max(0, activeLoads - 1)
            throw error
        }
    }

    func setLanguage(_ language: TranscriptionLanguage) async throws -> String? {
        languageRequest += 1
        let request = languageRequest
        cancelIdleEviction()
        if let explicitModel {
            // An explicit model selection is an intentional override. Do not
            // warm a second language model just because the menu setting
            // changes; that would defeat the single-resident-model guarantee.
            self.language = language
            scheduleIdleEviction()
            return explicitModel.modelID
        }
        let next = transcriber(for: language)
        activeLoads += 1
        do {
            try await next.warmUp()
        } catch {
            activeLoads = max(0, activeLoads - 1)
            throw error
        }
        guard request == languageRequest else {
            await finishLoad()
            return nil
        }
        self.language = language
        cleanupRequested = true
        if language != .german {
            prefetchGermanSpecialist()
        }
        await finishLoad()
        if language == .automatic {
            return "automatic · one multilingual model"
        }
        return next.modelID
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        cancelIdleEviction()
        activeTranscriptions += 1
        do {
            let raw: String
            if let explicitModel {
                raw = try await explicitModel.transcribe(audio)
            } else {
                switch language {
                case .english:
                    raw = try await multilingual.transcribe(audio, languageCode: "en")
                case .german:
                    raw = try await german.transcribe(audio)
                case .automatic:
                    let detection = try await multilingual.detectLanguage(audio)
                    let route = AutomaticLanguageRouter.route(detection)
                    let rawScore = detection.logProbabilities[detection.language] ?? -.infinity
                    FileHandle.standardError.write(Data(
                        "  detected \(detection.language) · logp \(rawScore) · route \(route) · shared model\n".utf8
                    ))
                    // Preserve Whisper's detected language, including languages
                    // outside the English/German specialist pair. The route is
                    // retained as a confidence diagnostic, not as a second model
                    // selection, so Automatic keeps one model resident.
                    let detectedLanguage = detection.language.isEmpty
                        ? nil
                        : detection.language
                    raw = try await multilingual.transcribe(
                        audio,
                        languageCode: detectedLanguage
                    )
                }
            }
            let result = dictionary.apply(to: raw)
            await finishTranscription()
            return result
        } catch {
            await finishTranscription()
            throw error
        }
    }

    private func transcriber(for language: TranscriptionLanguage) -> any Transcriber {
        switch language {
        case .automatic, .english: multilingual
        case .german: german
        }
    }

    /// Called by the menu-bar process when macOS reports memory pressure.
    /// During a decode we defer release until the active operation has finished.
    func handleMemoryPressure() async {
        cancelIdleEviction()
        if activeTranscriptions > 0 || activeLoads > 0 {
            memoryPressurePending = true
            cleanupRequested = true
            return
        }
        await unloadAll()
    }

    /// Exposed for cancellation/shutdown paths and for tests that want to
    /// exercise the lifecycle without waiting for the idle timeout.
    func scheduleIdleEviction() {
        cancelIdleEviction()
        idleEvictionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.idleEvictionNanoseconds)
            } catch {
                return
            }
            await self?.evictIfIdle()
        }
    }

    private func finishTranscription() async {
        activeTranscriptions = max(0, activeTranscriptions - 1)
        guard activeTranscriptions == 0, activeLoads == 0 else { return }

        if memoryPressurePending {
            await unloadAll()
        } else if cleanupRequested {
            await unloadInactiveIfSafe()
            scheduleIdleEviction()
        } else {
            scheduleIdleEviction()
        }
    }

    private func evictIfIdle() async {
        idleEvictionTask = nil
        guard activeTranscriptions == 0, activeLoads == 0 else { return }
        await unloadAll()
    }

    private func finishLoad() async {
        activeLoads = max(0, activeLoads - 1)
        guard activeLoads == 0, activeTranscriptions == 0 else { return }

        if memoryPressurePending {
            await unloadAll()
        } else if cleanupRequested {
            await unloadInactiveIfSafe()
            scheduleIdleEviction()
        } else {
            scheduleIdleEviction()
        }
    }

    private func unloadInactiveIfSafe() async {
        guard activeTranscriptions == 0, activeLoads == 0 else {
            cleanupRequested = true
            return
        }
        guard explicitModel == nil else {
            cleanupRequested = false
            return
        }

        switch language {
        case .automatic, .english:
            await german.unload()
        case .german:
            await multilingual.unload()
        }
        cleanupRequested = false
    }

    private func unloadAll() async {
        guard activeTranscriptions == 0, activeLoads == 0 else {
            memoryPressurePending = true
            cleanupRequested = true
            return
        }
        cancelIdleEviction()
        if let explicitModel {
            await explicitModel.unload()
        } else {
            await multilingual.unload()
            await german.unload()
        }
        memoryPressurePending = false
        cleanupRequested = false
        RuntimeMemoryLog.write("all-models-released")
    }

    private func cancelIdleEviction() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
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

    private func prefetchGermanSpecialist() {
        guard let germanModel = ModelRegistry.preferred(for: .german)
        else { return }
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
