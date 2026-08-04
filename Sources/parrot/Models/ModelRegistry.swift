import Foundation
import WhisperKit

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-large-v3-quantized",
            displayName: "Whisper Large v3 (Quantized)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_626MB",
            sizeMB: 626,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo-quantized",
            displayName: "Whisper Large v3 Turbo (Quantized)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo_632MB",
            sizeMB: 632,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-base",
            displayName: "Whisper Base (Multilingual)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base",
            sizeMB: 147,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small",
            displayName: "Whisper Small (Multilingual Detector)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small",
            sizeMB: 488,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo-german-q5",
            displayName: "Whisper Large v3 Turbo (German)",
            engine: .whisperCpp,
            sizeMB: 548,
            languages: ["de"],
            recommended: false,
            downloadURL: URL(
                string: "https://huggingface.co/MolyProduction/whisper-large-v3-turbo-german-ggml-q5_0/resolve/8ca650615c50e0d16a49de2bf707d2791242d829/ggml-large-v3-turbo-german-q5_0.bin"
            ),
            sha256: "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030"
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        preferred(for: .automatic) ?? shared.first { $0.recommended } ?? shared.first
    }

    static func preferred(for language: TranscriptionLanguage) -> TranscriptionModel? {
        switch language {
        case .english:
            return defaultLargeModel()
        case .automatic:
            // Automatic mode intentionally uses the same multilingual model
            // for detection and transcription. This avoids keeping a 488 MB
            // detector beside the active Large model.
            return defaultLargeModel()
        case .german:
            return find("whisper-large-v3-turbo-german-q5")
        }
    }

    /// Keep full Turbo as the default quality-preserving model. On the current
    /// M1 Pro, measured physical footprint during Core ML specialization was
    /// lower for full Turbo than for either quantized Large candidate, even
    /// though the quantized files are much smaller on disk. They remain
    /// explicit candidates so newer hardware can be benchmarked independently.
    static func defaultLargeModel() -> TranscriptionModel? {
        find("whisper-large-v3-turbo")
    }

    /// Returns quantized Large candidates advertised by the pinned WhisperKit
    /// hardware catalog. Explicit `--model` selection also permits testing a
    /// catalog variant that is not in the current machine's recommended list.
    static func quantizedLargeModels() -> [TranscriptionModel] {
        let preferredIDs: [(whisperKitID: String, modelID: String)] = [
            (
                "openai_whisper-large-v3-v20240930_turbo_632MB",
                "whisper-large-v3-turbo-quantized"
            ),
            (
                "openai_whisper-large-v3-v20240930_626MB",
                "whisper-large-v3-quantized"
            ),
        ]

        return preferredIDs.compactMap { candidate in
            guard supportedWhisperKitModelIDs.contains(candidate.whisperKitID) else {
                return nil
            }
            return find(candidate.modelID)
        }
    }

    private static let supportedWhisperKitModelIDs = Set(
        WhisperKit.recommendedModels().supported
    )
}
