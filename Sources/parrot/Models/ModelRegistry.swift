import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small",
            displayName: "Whisper Small",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small",
            sizeMB: 488,
            languages: ["multi"],
            recommended: true
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
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        preferred(for: .automatic) ?? shared.first { $0.recommended } ?? shared.first
    }

    static func preferred(
        for language: TranscriptionLanguage,
        modelPreference: TranscriptionModelPreference = .small
    ) -> TranscriptionModel? {
        switch language {
        case .english, .automatic:
            return find(modelPreference.modelID)
        case .german:
            return find("whisper-large-v3-turbo-german-q5")
        }
    }
}
