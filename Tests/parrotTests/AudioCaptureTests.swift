import AVFoundation
import XCTest
@testable import parrot

final class AudioCaptureTests: XCTestCase {
    func testStartIsIdempotentWhileStartingAndRecording() throws {
        let engine = FakeAudioCaptureEngine()
        engine.fakeInputNode.tapInstalled = true
        let capture = AudioCapture(engine: engine)
        var reentrantStartAttempted = false

        engine.onInputNodeAccess = {
            reentrantStartAttempted = true
            do {
                try capture.start()
            } catch {
                XCTFail("Reentrant start unexpectedly failed: \(error)")
            }
        }
        engine.fakeInputNode.onInstall = {
            reentrantStartAttempted = true
            do {
                try capture.start()
            } catch {
                XCTFail("Reentrant install start unexpectedly failed: \(error)")
            }
        }

        try capture.start()
        try capture.start()

        XCTAssertTrue(reentrantStartAttempted)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.fakeInputNode.installCount, 1)
        XCTAssertEqual(engine.fakeInputNode.removeCount, 1)
        XCTAssertEqual(engine.fakeInputNode.installSawExistingTap, [false])

        XCTAssertEqual(capture.stop(), [])
    }

    func testStopRemovesTapAndIsIdempotent() throws {
        let engine = FakeAudioCaptureEngine()
        let capture = AudioCapture(engine: engine)

        try capture.start()
        XCTAssertEqual(capture.stop(), [])
        XCTAssertEqual(capture.stop(), [])

        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.resetCount, 1)
        XCTAssertEqual(engine.fakeInputNode.removeCount, 2)
        XCTAssertFalse(engine.fakeInputNode.tapInstalled)
    }

    func testEngineStartFailureCleansUpAndReturnsToIdle() throws {
        let engine = FakeAudioCaptureEngine()
        engine.fakeInputNode.tapInstalled = true
        engine.startError = StartupError()
        let capture = AudioCapture(engine: engine)

        do {
            try capture.start()
            XCTFail("Expected engine startup to fail")
        } catch let error as AudioCapture.CaptureError {
            guard case .engineStartFailed = error else {
                XCTFail("Unexpected capture error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.resetCount, 1)
        XCTAssertEqual(engine.fakeInputNode.removeCount, 2)
        XCTAssertFalse(engine.fakeInputNode.tapInstalled)
        XCTAssertEqual(capture.stop(), [])

        // A failed start must leave the lifecycle idle so a later attempt can
        // install exactly one fresh tap after another defensive removal.
        engine.startError = nil
        engine.fakeInputNode.tapInstalled = true
        try capture.start()

        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(engine.fakeInputNode.installCount, 2)
        XCTAssertEqual(engine.fakeInputNode.removeCount, 3)
        XCTAssertEqual(engine.fakeInputNode.installSawExistingTap, [false, false])
        XCTAssertEqual(capture.stop(), [])
    }
}

private struct StartupError: Error {}

private final class FakeAudioCaptureEngine: AudioCaptureEngine {
    let fakeInputNode: FakeAudioCaptureInputNode
    var onInputNodeAccess: (() -> Void)?
    var startError: Error?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resetCount = 0

    init() {
        fakeInputNode = FakeAudioCaptureInputNode()
    }

    var inputNode: AudioCaptureInputNode {
        let callback = onInputNodeAccess
        onInputNodeAccess = nil
        callback?()
        return fakeInputNode
    }

    func prepare() {
        prepareCount += 1
    }

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCount += 1
    }

    func reset() {
        resetCount += 1
    }
}

private final class FakeAudioCaptureInputNode: AudioCaptureInputNode {
    let format = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 1
    )!
    var tapInstalled = false
    var onInstall: (() -> Void)?
    var installSawExistingTap: [Bool] = []
    private(set) var installCount = 0
    private(set) var removeCount = 0

    func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
        format
    }

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        block: @escaping AudioCaptureTap
    ) {
        installCount += 1
        installSawExistingTap.append(tapInstalled)
        tapInstalled = true
        let callback = onInstall
        onInstall = nil
        callback?()
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        removeCount += 1
        tapInstalled = false
    }
}
