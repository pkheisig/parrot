import Foundation
import CoreML
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let language: TranscriptionLanguage
    private var pipeline: WhisperKit?
    private var bufferedStream: ActiveBufferedStream?

    private struct ActiveBufferedStream {
        let transcriber: AudioStreamTranscriber
        let stateBox: BufferedStreamStateBox
        let task: Task<Void, Error>
    }

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage = .english
    ) {
        self.modelID = model.id
        self.model = model
        // English-only checkpoints cannot perform language detection.
        self.language = model.languages.contains("multi") ? language : .english
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
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
            computeOptions: computeOptions,
            verbose: false,
            prewarm: false,
            load: true
        )
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

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

    /// Starts WhisperKit's segment-confirming live decoder. Text remains
    /// private until `finishBufferedStream()`; only the waveform level escapes.
    func startBufferedStream(
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        guard bufferedStream == nil else { return }
        if pipeline == nil { try await warmUp() }
        guard let pipeline, let tokenizer = pipeline.tokenizer else {
            throw TranscriberError.notLoaded
        }

        let stateBox = BufferedStreamStateBox()
        let stream = AudioStreamTranscriber(
            audioEncoder: pipeline.audioEncoder,
            featureExtractor: pipeline.featureExtractor,
            segmentSeeker: pipeline.segmentSeeker,
            textDecoder: pipeline.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipeline.audioProcessor,
            decodingOptions: Self.decodingOptions(for: language),
            requiredSegmentsForConfirmation: 1,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: true
        ) { _, state in
            stateBox.update(state)
            if let level = state.bufferEnergy.last {
                onLevel(level)
            }
        }
        let task = Task {
            try await stream.startStreamTranscription()
        }
        bufferedStream = ActiveBufferedStream(
            transcriber: stream,
            stateBox: stateBox,
            task: task
        )

        // Do not report recording as started until WhisperKit's audio engine is
        // live. This also turns microphone/startup failures into normal errors.
        for _ in 0..<40 {
            if stateBox.snapshot?.isRecording == true { return }
            if task.isCancelled { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        await stream.stopStreamTranscription()
        task.cancel()
        _ = try? await task.value
        bufferedStream = nil
        throw TranscriberError.streamStartTimedOut
    }

    func finishBufferedStream() async throws -> BufferedTranscriptionResult {
        guard let active = bufferedStream, let pipeline else {
            throw TranscriberError.noActiveStream
        }
        await active.transcriber.stopStreamTranscription()
        // Release must not wait for a stale whole-buffer inference that happened
        // to start just before the key came up. Keep the most recently published
        // segments, cancel that pass, then decode only the unresolved tail below.
        active.task.cancel()
        _ = try? await active.task.value

        let samples = Array(pipeline.audioProcessor.audioSamples)
        let state = active.stateBox.snapshot
        bufferedStream = nil

        let segments = state.map(BufferedTranscriptAssembler.orderedSegments) ?? []
        let draft = Self.sanitize(segments.map(\.text).joined(separator: " "))
        guard !samples.isEmpty else {
            return BufferedTranscriptionResult(samples: [], text: draft)
        }

        // Re-decode only a short overlap plus audio recorded after the latest
        // completed stream segment. If no segment completed, fall back to the
        // original whole-recording path for correctness.
        guard let lastSegment = segments.last, !draft.isEmpty else {
            return BufferedTranscriptionResult(
                samples: samples,
                text: try await transcribe(samples)
            )
        }
        let duration = Double(samples.count) / Double(WhisperKit.sampleRate)
        let tailStartSeconds = max(0, min(duration, Double(lastSegment.end) - 0.8))
        let tailStart = min(
            samples.count,
            max(0, Int(tailStartSeconds * Double(WhisperKit.sampleRate)))
        )
        let tail = Array(samples[tailStart...])
        guard tail.count >= WhisperKit.sampleRate / 4 else {
            return BufferedTranscriptionResult(samples: samples, text: draft)
        }
        let tailText = try await transcribe(tail)
        return BufferedTranscriptionResult(
            samples: samples,
            text: TranscriptMerger.merge(prefix: draft, suffix: tailText)
        )
    }

    func cancelBufferedStream() async {
        guard let active = bufferedStream else { return }
        await active.transcriber.stopStreamTranscription()
        active.task.cancel()
        _ = try? await active.task.value
        bufferedStream = nil
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
        _ = try await WhisperKit.download(variant: whisperKitID)
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

    func supportsBufferedStreaming() -> Bool {
        explicitModel == nil && language == .english
    }

    func startBufferedStream(
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        guard supportsBufferedStreaming() else {
            throw TranscriberError.streamingUnavailable
        }
        try await english.startBufferedStream(onLevel: onLevel)
    }

    func finishBufferedStream() async throws -> BufferedTranscriptionResult {
        let result = try await english.finishBufferedStream()
        return BufferedTranscriptionResult(
            samples: result.samples,
            text: dictionary.apply(to: result.text)
        )
    }

    func cancelBufferedStream() async {
        await english.cancelBufferedStream()
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
    case streamingUnavailable
    case noActiveStream
    case streamStartTimedOut
}

struct BufferedTranscriptionResult: Sendable {
    let samples: [Float]
    let text: String
}

private final class BufferedStreamStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AudioStreamTranscriber.State?

    var snapshot: AudioStreamTranscriber.State? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ state: AudioStreamTranscriber.State) {
        lock.lock()
        self.state = state
        lock.unlock()
    }
}

enum BufferedTranscriptAssembler {
    static func orderedSegments(
        from state: AudioStreamTranscriber.State
    ) -> [TranscriptionSegment] {
        orderedSegments(
            confirmed: state.confirmedSegments,
            unconfirmed: state.unconfirmedSegments
        )
    }

    static func orderedSegments(
        confirmed: [TranscriptionSegment],
        unconfirmed: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        let candidates = confirmed + unconfirmed
        var seen = Set<String>()
        return candidates
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
            .filter { segment in
                let key = "\(segment.start)|\(segment.end)|\(segment.text)"
                return seen.insert(key).inserted
            }
    }
}

enum TranscriptMerger {
    static func merge(prefix: String, suffix: String) -> String {
        let prefix = clean(prefix)
        let suffix = clean(suffix)
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }

        let left = tokens(in: prefix)
        let right = tokens(in: suffix)
        let maximum = min(16, left.count, right.count)
        var overlap = 0
        if maximum > 0 {
            for count in stride(from: maximum, through: 1, by: -1) {
                let leftWords = left.suffix(count).map(\.normalized)
                let rightWords = right.prefix(count).map(\.normalized)
                if leftWords == rightWords {
                    overlap = count
                    break
                }
            }
        }

        let remainder: String
        if overlap > 0, let end = Range(right[overlap - 1].range, in: suffix)?.upperBound {
            remainder = String(suffix[end...])
                .replacingOccurrences(
                    of: #"^[\s\p{P}]+"#,
                    with: "",
                    options: .regularExpression
                )
        } else {
            remainder = suffix
        }
        guard !remainder.isEmpty else { return prefix }
        return clean(prefix + " " + remainder)
    }

    private struct WordToken {
        let normalized: String
        let range: NSRange
    }

    private static func tokens(in text: String) -> [WordToken] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return WordToken(
                normalized: text[swiftRange].lowercased(),
                range: match.range
            )
        }
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
