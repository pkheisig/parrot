import Foundation

enum Engine: String, Codable {
    case whisperKit
    case whisperCpp
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// Engine-specific identifier (e.g. "openai_whisper-small" for WhisperKit).
    let whisperKitID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
    /// Direct model download used by engines that do not use WhisperKit's
    /// Hugging Face repository layout.
    let downloadURL: URL?
    let sha256: String?

    init(
        id: String,
        displayName: String,
        engine: Engine,
        whisperKitID: String? = nil,
        sizeMB: Int,
        languages: [String],
        recommended: Bool,
        downloadURL: URL? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.whisperKitID = whisperKitID
        self.sizeMB = sizeMB
        self.languages = languages
        self.recommended = recommended
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
