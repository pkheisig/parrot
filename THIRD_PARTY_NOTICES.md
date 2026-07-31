# Third-party notices

Parrot uses these third-party components and model assets:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit), MIT License.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp), MIT License. The
  application bundle embeds its official macOS XCFramework release.
- [OpenAI Whisper](https://github.com/openai/whisper), MIT License. WhisperKit
  downloads the multilingual Small and English Base model conversions on demand.
- [primeline/whisper-large-v3-turbo-german](https://huggingface.co/primeline/whisper-large-v3-turbo-german),
  Apache License 2.0. Parrot downloads the Q5_0 GGML conversion published by
  [MolyProduction](https://huggingface.co/MolyProduction/whisper-large-v3-turbo-german-ggml-q5_0).
- [swift-argument-parser](https://github.com/apple/swift-argument-parser),
  Apache License 2.0.

The model files are not redistributed in the repository or application
bundle. They are fetched on the user's Mac and cached locally.
