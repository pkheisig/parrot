import Foundation
import CoreML
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let language: TranscriptionLanguage
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel, language: TranscriptionLanguage = .english) {
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
        return Self.sanitize(raw)
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

actor TranscriptionService {
    private var active: WhisperKitTranscriber
    private var language: TranscriptionLanguage
    private var languageRequest = 0

    init(model: TranscriptionModel, language: TranscriptionLanguage) {
        self.active = WhisperKitTranscriber(model: model, language: language)
        self.language = language
    }

    func warmUp() async throws {
        try await active.warmUp()
    }

    func setLanguage(_ language: TranscriptionLanguage) async throws -> String? {
        languageRequest += 1
        let request = languageRequest
        guard language != self.language else {
            return active.modelID
        }
        guard let model = ModelRegistry.preferred(for: language) else {
            throw TranscriberError.modelUnavailable
        }

        let next = WhisperKitTranscriber(model: model, language: language)
        try await next.warmUp()
        guard request == languageRequest else { return nil }
        active = next
        self.language = language
        return model.id
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        try await active.transcribe(audio)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
    case modelUnavailable
}
