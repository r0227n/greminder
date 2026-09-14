import AVFoundation
import ComposableArchitecture
import Foundation
import WhisperKit

struct SpeechClient: Sendable {
    static let maximumRecordingSeconds = 60

    var prepare: @Sendable (UUID, SpeechPreferences) async throws -> Void
    var start: @Sendable (UUID) async throws -> Void
    var transcribe: @Sendable (UUID) async throws -> String
    var cancel: @Sendable (UUID) async -> Void
}

extension SpeechClient: DependencyKey {
    static let liveValue = Self(
        prepare: { try await WhisperSpeechEngine.shared.prepare($1, sessionID: $0) },
        start: { try await WhisperSpeechEngine.shared.start(id: $0) },
        transcribe: { try await WhisperSpeechEngine.shared.finish(id: $0) },
        cancel: { await WhisperSpeechEngine.shared.cancel(id: $0) },
    )
    static let testValue = Self(
        prepare: { _, _ in throw AppFailure("speech.prepare dependency must be supplied") },
        start: { _ in throw AppFailure("speech.start dependency must be supplied") },
        transcribe: { _ in throw AppFailure("speech.transcribe dependency must be supplied") },
        cancel: { _ in },
    )
}

extension DependencyValues {
    var speech: SpeechClient {
        get { self[SpeechClient.self] }
        set { self[SpeechClient.self] = newValue }
    }
}

/// AVAudioRecorder owns the microphone. WhisperKit only reads the stopped recording.
/// No audio or transcript is sent to a transcription service.
@MainActor
final class WhisperSpeechEngine {
    static let shared = WhisperSpeechEngine()
    static let maximumDuration = TimeInterval(SpeechClient.maximumRecordingSeconds)

    private struct PreparedModel {
        let model: SpeechModel
        let pipe: WhisperKit
    }

    private struct Session {
        let id: UUID
        let preferences: SpeechPreferences
    }

    private var prepared: PreparedModel?
    private var session: Session?
    typealias ModelLoader = @MainActor @Sendable (SpeechModel, URL) async throws -> WhisperKit

    private let loadModel: ModelLoader
    private var loading: Task<Void, Error>?
    private var loadID: UUID?
    private var transcription: Task<String, Error>?
    private var transcriptionID: UUID?
    private var recorder: AVAudioRecorder?
    private var recordingID: UUID?
    private var recordingURL: URL?
    private let availableBytes: @Sendable (URL) throws -> Int64?
    let modelCache: URL

    init(
        modelCache: URL? = nil,
        availableBytes: @escaping @Sendable (URL) throws -> Int64? = { try SpeechStorage.availableBytes(at: $0) },
        loadModel: ModelLoader? = nil,
    ) {
        self.availableBytes = availableBytes
        self.loadModel = loadModel ?? { model, cache in
            try await Self.loadPipeline(model: model, cache: cache, availableBytes: availableBytes)
        }
        self.modelCache = modelCache ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Greminder/WhisperKit", isDirectory: true)
    }

    /// A voice sheet owns its selected model and language until it releases the session.
    /// Another window cannot change those settings or cancel its preparation.
    func prepare(_ preferences: SpeechPreferences, sessionID id: UUID) async throws {
        try Task.checkCancellation()
        guard session == nil || session?.id == id else {
            throw AppFailure(L10n.tr("音声入力は別のウインドウで使用中です。"))
        }
        guard recordingID == nil else {
            throw AppFailure(L10n.tr("録音・文字起こしが完了してからモデルを切り替えてください。"))
        }
        session = Session(id: id, preferences: preferences)
        do {
            try FileManager.default.createDirectory(at: modelCache, withIntermediateDirectories: true)
            try checkStorage(for: preferences.model)
            // A cancelled inference may still be releasing its model buffers.
            if let previous = transcription {
                previous.cancel()
                _ = try? await previous.value
                try Task.checkCancellation()
                guard session?.id == id else { throw CancellationError() }
            }
            // Drain a cancelled SDK load before starting another expensive Core ML load.
            if let previous = loading {
                previous.cancel()
                _ = try? await previous.value
                try Task.checkCancellation()
                guard session?.id == id else { throw CancellationError() }
            }
            if prepared?.model == preferences.model { return }
            prepared = nil
            loadID = id
            let task = Task<Void, Error> { @MainActor [modelCache] in
                try Task.checkCancellation()
                let pipeline = try await self.loadModel(preferences.model, modelCache)
                try Task.checkCancellation()
                guard self.session?.id == id else { throw CancellationError() }
                self.prepared = PreparedModel(model: preferences.model, pipe: pipeline)
            }
            loading = task
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard session?.id == id else { throw CancellationError() }
            loading = nil
            loadID = nil
        } catch {
            let wasCancelled = Task.isCancelled || session?.id != id
            if session?.id == id { session = nil }
            if loadID == id { loading = nil
                loadID = nil
            }
            if wasCancelled { throw CancellationError() }
            throw error
        }
    }

    func start(id: UUID) async throws {
        try Task.checkCancellation()
        guard let session, session.id == id, prepared?.model == session.preferences.model else {
            throw AppFailure(L10n.tr("音声モデルを準備してください。"))
        }
        guard recordingID == nil else { throw AppFailure(L10n.tr("音声入力は別のウインドウで使用中です。")) }
        try checkStorage(for: session.preferences.model)
        recordingID = id
        let granted = await AudioProcessor.requestRecordPermission()
        guard recordingID == id, self.session?.id == id, !Task.isCancelled else {
            if recordingID == id { cleanupRecording() }
            throw CancellationError()
        }
        guard granted else {
            cleanupRecording()
            throw AppFailure(L10n.tr("マイクを使用できません。システム設定でgreminderのマイクへのアクセスを許可してください。"))
        }
        do {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                try session.setActive(true)
            #endif
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("greminder-voice-\(id.uuidString).caf")
            recordingURL = url
            let capture = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            recorder = capture
            guard capture.prepareToRecord(), capture.record(forDuration: Self.maximumDuration) else {
                throw AppFailure(L10n.tr("録音を開始できませんでした。マイクが接続されているか確認してください。"))
            }
        } catch {
            cleanupRecording()
            throw error
        }
    }

    func finish(id: UUID) async throws -> String {
        guard recordingID == id, let url = recordingURL else { throw AppFailure(L10n.tr("録音データがありません。")) }
        recorder?.stop()
        deactivateAudioSession()
        defer {
            if recordingID == id { cleanupRecording() }
            if transcriptionID == id { transcription = nil
                transcriptionID = nil
            }
        }
        let work = Task { @MainActor in try await self.transcribeFile(url) }
        transcription = work
        transcriptionID = id
        let result = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard recordingID == id, session?.id == id else { throw CancellationError() }
        return result
    }

    /// Also used by an opt-in integration test with a synthetic speech fixture.
    func transcribeFile(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        guard let prepared, let session,
              prepared.model == session.preferences.model else { throw AppFailure(L10n.tr("音声モデルを準備してください。")) }
        try checkStorage(for: session.preferences.model)
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        guard samples.count >= 4800, samples.count <= Int(Self.maximumDuration + 1) * 16000 else {
            throw AppFailure(L10n.tr("0.3秒から60秒の音声を録音してください。"))
        }
        // Reject digital silence before decoding: Whisper can hallucinate text on silence.
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        guard energy > 0.000001 else { throw AppFailure(L10n.tr("音声を聞き取れませんでした。マイクに近づいて録音し直してください。")) }
        let options = Self.decodingOptions(for: session.preferences.language)
        let results = try await prepared.pipe.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        let text = results.flatMap(\.segments)
            .filter { $0.noSpeechProb < 0.6 }
            .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppFailure(L10n.tr("音声を聞き取れませんでした。もう一度録音してください。")) }
        return text
    }

    static func decodingOptions(for language: SpeechLanguage) -> DecodingOptions {
        DecodingOptions(
            language: language.code,
            temperatureFallbackCount: 2,
            detectLanguage: language == .automatic,
            skipSpecialTokens: true,
            withoutTimestamps: true,
        )
    }

    func cancel(id: UUID) {
        guard session?.id == id else { return }
        if recordingID == id { cleanupRecording() }
        if loadID == id { loading?.cancel() }
        if transcriptionID == id { transcription?.cancel() }
        session = nil
    }

    private static func loadPipeline(
        model: SpeechModel,
        cache: URL,
        availableBytes: @Sendable (URL) throws -> Int64?,
    ) async throws -> WhisperKit {
        let locationFile = cache.appendingPathComponent("\(model.rawValue)-location.txt")
        let legacyFile = cache.appendingPathComponent("model-location.txt")
        let cachedPath = (try? String(contentsOf: locationFile, encoding: .utf8)) ??
            (model == .base ? try? String(contentsOf: legacyFile, encoding: .utf8) : nil)
        let folder: URL = if let cachedPath, cachedPath.hasPrefix(cache.path + "/"),
                             FileManager.default.fileExists(atPath: cachedPath)
        {
            URL(fileURLWithPath: cachedPath)
        } else {
            try await WhisperKit.download(variant: model.rawValue, downloadBase: cache)
        }
        try Task.checkCancellation()
        try SpeechStorage.validate(availableBytes: availableBytes(cache), model: model)
        let pipeline = try await WhisperKit(WhisperKitConfig(
            model: model.rawValue, modelFolder: folder.path, tokenizerFolder: cache,
            verbose: false, prewarm: false, load: true, download: false,
        ))
        try Task.checkCancellation()
        // Persist only after both the model and tokenizer are available for offline use.
        try folder.path.write(to: locationFile, atomically: true, encoding: .utf8)
        return pipeline
    }

    private func checkStorage(for model: SpeechModel) throws {
        try SpeechStorage.validate(availableBytes: availableBytes(modelCache), model: model)
    }

    private func cleanupRecording() {
        recorder?.stop()
        recorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        recordingID = nil
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
