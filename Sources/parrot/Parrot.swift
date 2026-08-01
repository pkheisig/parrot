import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon with a configurable global hotkey.",
        subcommands: [
            Run.self, Setup.self, Doctor.self, Models.self, Install.self,
            TranscribeFile.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    func run() throws {
        let settings = DictationSettings()
        let dictionary = CorrectionDictionaryStore()
        let isAppBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        if !skipDoctor, !isAppBundle {
            let checks = DoctorReport.run(shortcut: settings.shortcut)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.preferred(for: settings.transcriptionLanguage) else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriptionService = TranscriptionService(
            model: chosenModel,
            language: settings.transcriptionLanguage,
            usesExplicitModel: model != nil,
            dictionary: dictionary
        )
        let readyModelID = settings.transcriptionLanguage == .automatic
            ? "automatic · English/German specialists"
            : chosenModel.id

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(
            shortcut: settings.shortcut,
            learningShortcut: settings.learningShortcut,
            debug: debugHotkey
        )
        let capture = AudioCapture()
        let learningController = MainActor.assumeIsolated {
            CorrectionLearningController()
        }
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        // The standalone CLI remains headless. Only the signed .app owns a
        // status item, avoiding the duplicate "parrot" identity macOS creates
        // for /usr/local/bin/parrot.
        let menuBar: MenuBarController? = MainActor.assumeIsolated {
            isAppBundle
                ? MenuBarController(
                    modelID: chosenModel.id,
                    settings: settings,
                    dictionary: dictionary
                )
                : nil
        }
        var activationMode = settings.activationMode
        var recordingMode = activationMode
        var isRecording = false
        var usesBufferedStream = false
        var bufferedStartTask: Task<Void, Error>?
        var recordingTarget: TextInjector.Target?
        var recordingSnapshot: FocusedTextSnapshot?
        let readiness = MainActor.assumeIsolated {
            RuntimeReadiness(modelReady: !isAppBundle)
        }
        MainActor.assumeIsolated {
            menuBar?.onShortcutChanged = { shortcut in
                monitor.setShortcut(shortcut)
            }
            menuBar?.onLearningShortcutChanged = { shortcut in
                monitor.setLearningShortcut(shortcut)
            }
            menuBar?.onActivationModeChanged = { mode in
                activationMode = mode
            }
            menuBar?.onLanguageChanged = { language in
                menuBar?.setLoading(language)
                Task {
                    do {
                        guard let modelID = try await transcriptionService.setLanguage(language)
                        else { return }
                        await MainActor.run {
                            menuBar?.setReady(modelID: modelID, language: language)
                        }
                    } catch {
                        FileHandle.standardError.write(Data(
                            "language model load failed: \(error)\n".utf8
                        ))
                        await MainActor.run {
                            menuBar?.setLanguageError("model load failed · try again")
                        }
                    }
                }
            }
        }

        let handleHotkey: (HotkeyMonitor.Event) -> Void = { event in
            switch event {
            case .pressed:
                guard MainActor.assumeIsolated({ readiness.modelReady }) else {
                    MainActor.assumeIsolated {
                        menuBar?.setUnavailable("model is still loading…")
                    }
                    return
                }
                if recordingMode == .toggle, isRecording {
                    isRecording = false
                    let deliveryTarget = TextInjector.captureTarget() ?? recordingTarget
                    let deliverySnapshot = FocusedTextSnapshot.capture() ?? recordingSnapshot
                    if usesBufferedStream {
                        finishBufferedTranscription(
                            startTask: bufferedStartTask,
                            transcriptionService: transcriptionService,
                            overlay: overlay,
                            menuBar: menuBar,
                            dumpWav: dumpWav,
                            learningController: learningController,
                            deliveryTarget: deliveryTarget,
                            deliverySnapshot: deliverySnapshot
                        )
                    } else {
                        let samples = capture.stop()
                        transcribe(
                            samples: samples,
                            transcriptionService: transcriptionService,
                            overlay: overlay,
                            menuBar: menuBar,
                            dumpWav: dumpWav,
                            learningController: learningController,
                            deliveryTarget: deliveryTarget,
                            deliverySnapshot: deliverySnapshot
                        )
                    }
                    usesBufferedStream = false
                    bufferedStartTask = nil
                    recordingTarget = nil
                    recordingSnapshot = nil
                    return
                }
                guard !isRecording else { return }
                recordingTarget = TextInjector.captureTarget()
                recordingSnapshot = FocusedTextSnapshot.capture()
                recordingMode = activationMode
                usesBufferedStream = model == nil
                    && settings.transcriptionLanguage == .english
                if usesBufferedStream {
                    bufferedStartTask = Task {
                        try await transcriptionService.startBufferedStream { level in
                            Task { @MainActor in
                                overlay?.pushLevel(level)
                            }
                        }
                    }
                } else {
                    do {
                        try capture.start()
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                        usesBufferedStream = false
                        return
                    }
                }
                isRecording = true
                FileHandle.standardError.write(Data(
                    usesBufferedStream ? "● recording + buffered decode\n".utf8 : "● recording\n".utf8
                ))
                MainActor.assumeIsolated {
                    overlay?.show(.recording)
                    menuBar?.setRecording(true)
                }
            case .released:
                guard recordingMode == .hold, isRecording else { return }
                isRecording = false
                let deliveryTarget = TextInjector.captureTarget() ?? recordingTarget
                let deliverySnapshot = FocusedTextSnapshot.capture() ?? recordingSnapshot
                if usesBufferedStream {
                    finishBufferedTranscription(
                        startTask: bufferedStartTask,
                        transcriptionService: transcriptionService,
                        overlay: overlay,
                        menuBar: menuBar,
                        dumpWav: dumpWav,
                        learningController: learningController,
                        deliveryTarget: deliveryTarget,
                        deliverySnapshot: deliverySnapshot
                    )
                } else {
                    let samples = capture.stop()
                    transcribe(
                        samples: samples,
                        transcriptionService: transcriptionService,
                        overlay: overlay,
                        menuBar: menuBar,
                        dumpWav: dumpWav,
                        learningController: learningController,
                        deliveryTarget: deliveryTarget,
                        deliverySnapshot: deliverySnapshot
                    )
                }
                usesBufferedStream = false
                bufferedStartTask = nil
                recordingTarget = nil
                recordingSnapshot = nil
            case .cancelRequested:
                guard isRecording else { return }
                isRecording = false
                if usesBufferedStream {
                    let startTask = bufferedStartTask
                    Task {
                        _ = try? await startTask?.value
                        await transcriptionService.cancelBufferedStream()
                    }
                } else {
                    _ = capture.stop()
                }
                usesBufferedStream = false
                bufferedStartTask = nil
                recordingTarget = nil
                recordingSnapshot = nil
                FileHandle.standardError.write(Data("recording canceled\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar?.setRecording(false)
                }
            case .learnCorrectionRequested:
                NSLog("Parrot Learn hotkey received")
                guard !isRecording else {
                    MainActor.assumeIsolated {
                        menuBar?.showLearningError(
                            "Finish or cancel the recording before learning a correction."
                        )
                    }
                    return
                }
                MainActor.assumeIsolated {
                    do {
                        let proposals = try learningController.proposals()
                        let learned = menuBar?.confirmCorrections(proposals) ?? 0
                        if learned > 0 {
                            learningController.clear()
                            menuBar?.setLearningStatus(
                                learned == 1
                                    ? "learned 1 correction"
                                    : "learned \(learned) corrections"
                            )
                        }
                    } catch {
                        menuBar?.showLearningError(error.localizedDescription)
                        NSLog(
                            "Parrot correction learning failed: %@",
                            error.localizedDescription
                        )
                        FileHandle.standardError.write(Data(
                            "learn correction failed: \(error.localizedDescription)\n".utf8
                        ))
                    }
                }
            }
        }

        if isAppBundle {
            MainActor.assumeIsolated {
                menuBar?.setLoading(settings.transcriptionLanguage)
            }

            do {
                try monitor.start(onEvent: handleHotkey)
                MainActor.assumeIsolated {
                    readiness.monitorStarted = true
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "failed to register hotkey tap: \(error)\n".utf8
                ))
                MainActor.assumeIsolated {
                    menuBar?.setUnavailable(
                        "Accessibility required · enable Parrot; it will reconnect"
                    )
                    _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                        guard AXIsProcessTrusted() else { return }
                        Task { @MainActor in
                            do {
                                try monitor.start(onEvent: handleHotkey)
                                readiness.monitorStarted = true
                                timer.invalidate()
                                if readiness.modelReady {
                                    menuBar?.setReady(
                                        modelID: readyModelID,
                                        language: settings.transcriptionLanguage
                                    )
                                } else {
                                    menuBar?.setLoading(settings.transcriptionLanguage)
                                }
                            } catch {
                                // Permission propagation can lag briefly after
                                // the Settings toggle. Keep retrying until the tap exists.
                            }
                        }
                    }
                }
            }

            Task {
                do {
                    try await transcriptionService.warmUp()
                } catch {
                    FileHandle.standardError.write(Data("warmup failed: \(error)\n".utf8))
                    await MainActor.run {
                        menuBar?.setLanguageError("model load failed · check your connection")
                    }
                    return
                }
                await MainActor.run {
                    readiness.modelReady = true
                    if readiness.monitorStarted {
                        menuBar?.setReady(
                            modelID: readyModelID,
                            language: settings.transcriptionLanguage
                        )
                    }
                }
            }
        } else {
            let warmupSemaphore = DispatchSemaphore(value: 0)
            var warmupError: Error?
            Task.detached {
                do {
                    try await transcriptionService.warmUp()
                } catch {
                    warmupError = error
                }
                warmupSemaphore.signal()
            }
            warmupSemaphore.wait()
            if let warmupError {
                FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
                throw ExitCode(1)
            }
            do {
                try monitor.start(onEvent: handleHotkey)
            } catch {
                FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
                throw ExitCode(1)
            }
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "listening on \(settings.shortcut.displayName) \(settings.activationMode.rawValue) · model: \(chosenModel.id) · ^C to quit\n"
                .utf8
        ))
        app.run()
    }
}

@MainActor
private final class RuntimeReadiness {
    var modelReady: Bool
    var monitorStarted = false

    init(modelReady: Bool) {
        self.modelReady = modelReady
    }
}

private func transcribe(
    samples: [Float],
    transcriptionService: TranscriptionService,
    overlay: RecordingOverlay?,
    menuBar: MenuBarController?,
    dumpWav: Bool,
    learningController: CorrectionLearningController,
    deliveryTarget: TextInjector.Target?,
    deliverySnapshot: FocusedTextSnapshot?
) {
    MainActor.assumeIsolated {
        overlay?.show(.transcribing)
        menuBar?.setTranscribing()
    }
    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
    let rms = computeRMS(samples)
    FileHandle.standardError.write(Data(
        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
    ))
    if dumpWav, !samples.isEmpty {
        let path = "/tmp/parrot-last.wav"
        do {
            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
        }
    }
    guard !samples.isEmpty else {
        MainActor.assumeIsolated {
            overlay?.hide()
            menuBar?.setRecording(false)
        }
        return
    }
    Task {
        let started = Date()
        do {
            let text = try await transcriptionService.transcribe(samples)
            let elapsed = Date().timeIntervalSince(started)
            FileHandle.standardError.write(Data(
                String(format: "→ %.2fs · %@\n", elapsed, text).utf8
            ))
            await MainActor.run {
                deliverTranscript(
                    text,
                    overlay: overlay,
                    menuBar: menuBar,
                    learningController: learningController,
                    deliveryTarget: deliveryTarget,
                    deliverySnapshot: deliverySnapshot
                )
            }
        } catch {
            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
            await MainActor.run {
                overlay?.hide()
                menuBar?.setRecording(false)
            }
        }
    }
}

private func finishBufferedTranscription(
    startTask: Task<Void, Error>?,
    transcriptionService: TranscriptionService,
    overlay: RecordingOverlay?,
    menuBar: MenuBarController?,
    dumpWav: Bool,
    learningController: CorrectionLearningController,
    deliveryTarget: TextInjector.Target?,
    deliverySnapshot: FocusedTextSnapshot?
) {
    MainActor.assumeIsolated {
        overlay?.show(.transcribing)
        menuBar?.setTranscribing()
    }
    Task {
        let started = Date()
        do {
            try await startTask?.value
            let result = try await transcriptionService.finishBufferedStream()
            let elapsed = Date().timeIntervalSince(started)
            let seconds = Double(result.samples.count) / AudioCapture.targetSampleRate
            let rms = computeRMS(result.samples)
            FileHandle.standardError.write(Data(
                String(
                    format: "○ buffered %.2fs · rms %.3f · release-to-text %.2fs\n",
                    seconds,
                    rms,
                    elapsed
                ).utf8
            ))
            if dumpWav, !result.samples.isEmpty {
                let path = "/tmp/parrot-last.wav"
                try WAVWriter.write(samples: result.samples, sampleRate: 16_000, to: path)
                FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
            }
            FileHandle.standardError.write(Data("→ \(result.text)\n".utf8))
            await MainActor.run {
                guard !result.text.isEmpty else {
                    overlay?.hide()
                    menuBar?.setRecording(false)
                    return
                }
                deliverTranscript(
                    result.text,
                    overlay: overlay,
                    menuBar: menuBar,
                    learningController: learningController,
                    deliveryTarget: deliveryTarget,
                    deliverySnapshot: deliverySnapshot
                )
            }
        } catch {
            FileHandle.standardError.write(Data(
                "buffered transcription failed: \(error)\n".utf8
            ))
            await transcriptionService.cancelBufferedStream()
            await MainActor.run {
                overlay?.hide()
                menuBar?.setRecording(false)
            }
        }
    }
}

@MainActor
private func deliverTranscript(
    _ text: String,
    overlay: RecordingOverlay?,
    menuBar: MenuBarController?,
    learningController: CorrectionLearningController,
    deliveryTarget: TextInjector.Target?,
    deliverySnapshot: FocusedTextSnapshot?
) {
    guard !text.isEmpty else {
        overlay?.hide()
        menuBar?.setRecording(false)
        return
    }
    let snapshot = deliverySnapshot ?? FocusedTextSnapshot.capture()
    let target = deliveryTarget ?? TextInjector.captureTarget()
    let delivery = TextInjector.deliver(text, to: target)
    learningController.remember(insertedText: text, snapshot: snapshot)
    menuBar?.setRecording(false)

    switch delivery {
    case .inserted:
        overlay?.hide()
    case .insertedWithClipboardBackup:
        FileHandle.standardError.write(Data(
            "opaque text target · inserted with clipboard backup\n".utf8
        ))
        overlay?.showCopiedToClipboard()
        menuBar?.setCopiedToClipboard()
    case .copiedToClipboard:
        FileHandle.standardError.write(Data(
            "no writable text target · copied transcript to clipboard\n".utf8
        ))
        overlay?.showCopiedToClipboard()
        menuBar?.setCopiedToClipboard()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and hotkey configuration."
    )

    func run() throws {
        let checks = DoctorReport.run(shortcut: DictationSettings().shortcut)
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t: any Transcriber
            switch m.engine {
            case .whisperKit:
                t = WhisperKitTranscriber(model: m)
            case .whisperCpp:
                t = WhisperCppTranscriber(model: m)
            }

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}

/// Internal smoke-test path for exercising the same language router as live
/// dictation without requiring microphone or Accessibility access.
struct TranscribeFile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe-file",
        abstract: "Transcribe an audio file (internal verification command).",
        shouldDisplay: false
    )

    @Argument(help: "Path to an audio file.")
    var path: String

    @Option(name: .long, help: "automatic, english, or german")
    var language: String = TranscriptionLanguage.automatic.rawValue

    @Option(name: .long, help: "Temporary correction alias for verification.")
    var correctionAlias: String?

    @Option(name: .long, help: "Temporary correction spelling for verification.")
    var correctionCanonical: String?

    func run() throws {
        guard let selectedLanguage = TranscriptionLanguage(rawValue: language) else {
            throw ValidationError("language must be automatic, english, or german")
        }
        guard let model = ModelRegistry.preferred(for: selectedLanguage) else {
            throw ValidationError("no model is registered for \(selectedLanguage.rawValue)")
        }

        guard (correctionAlias == nil) == (correctionCanonical == nil) else {
            throw ValidationError(
                "--correction-alias and --correction-canonical must be provided together"
            )
        }
        let dictionary: CorrectionDictionaryStore
        if let correctionAlias, let correctionCanonical {
            dictionary = CorrectionDictionaryStore(persistent: false)
            guard dictionary.upsert(
                alias: correctionAlias,
                canonical: correctionCanonical
            ) != nil else {
                throw ValidationError("temporary correction is invalid")
            }
        } else {
            dictionary = CorrectionDictionaryStore()
        }

        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let service = TranscriptionService(
            model: model,
            language: selectedLanguage,
            dictionary: dictionary
        )
        let semaphore = DispatchSemaphore(value: 0)
        var capturedResult: Result<String, Error>?
        Task.detached {
            do {
                try await service.warmUp()
                capturedResult = .success(try await service.transcribe(samples))
            } catch {
                capturedResult = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch capturedResult {
        case let .success(text):
            print(text)
        case let .failure(error):
            throw error
        case nil:
            throw TranscriberError.notLoaded
        }
    }
}
