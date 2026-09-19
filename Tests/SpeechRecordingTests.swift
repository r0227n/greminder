import AVFoundation
import ComposableArchitecture
@testable import GreminderKit
import XCTest

@MainActor
final class SpeechRecordingTests: XCTestCase {
    func testLongRecordingWithSpeechAfterOneMinuteIsAccepted() async throws {
        let url = try makeRecording(duration: 75, speechStartsAt: 65)
        defer { try? FileManager.default.removeItem(at: url) }
        try await WhisperSpeechEngine.validateRecording(url)
    }

    func testLongSilentRecordingIsRejected() async throws {
        let url = try makeRecording(duration: 75, speechStartsAt: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults.inMemory
        defaults.set("ja", forKey: L10n.preferenceKey)
        await withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            do {
                try await WhisperSpeechEngine.validateRecording(url)
                XCTFail("A silent recording must not reach the decoder")
            } catch {
                XCTAssertTrue((error as? AppFailure)?.message.contains("音声を聞き取れませんでした") == true)
            }
        }
    }

    func testVeryShortRecordingIsRejected() async throws {
        let url = try makeRecording(duration: 0.2, speechStartsAt: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults.inMemory
        defaults.set("ja", forKey: L10n.preferenceKey)
        await withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            do {
                try await WhisperSpeechEngine.validateRecording(url)
                XCTFail("A recording below the minimum duration must be rejected")
            } catch {
                XCTAssertEqual((error as? AppFailure)?.message, "0.3秒以上の音声を録音してください。")
            }
        }
    }

    private func makeRecording(duration: TimeInterval, speechStartsAt: TimeInterval?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let totalFrames = Int(duration * format.sampleRate)
        let speechFrame = speechStartsAt.map { Int($0 * format.sampleRate) } ?? totalFrames
        var written = 0
        while written < totalFrames {
            buffer.frameLength = AVAudioFrameCount(min(Int(buffer.frameCapacity), totalFrames - written))
            for frame in 0 ..< Int(buffer.frameLength) {
                let position = written + frame
                samples[frame] = position >= speechFrame ? sin(Float(position) * 2 * .pi * 440 / 16000) * 0.125 : 0
            }
            try file.write(from: buffer)
            written += Int(buffer.frameLength)
        }
        return url
    }
}
