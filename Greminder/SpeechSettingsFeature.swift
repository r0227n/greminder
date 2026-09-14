import ComposableArchitecture
import Foundation

enum SpeechModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: L10n.tr("Tiny — 軽量")
        case .base: L10n.tr("Base — 標準")
        case .small: L10n.tr("Small — 精度を優先")
        case .largeV3Turbo: "Large v3 Turbo"
        }
    }

    var detail: String {
        switch self {
        case .tiny: L10n.tr("軽量で準備・処理が速いモデルです。認識精度より速度を優先する場合に使います。")
        case .base: L10n.tr("速度と認識精度のバランスを取った多言語モデルです。")
        case .small: L10n.tr("TinyやBaseよりメモリと空き容量を使い、処理に時間がかかります。")
        case .largeV3Turbo:
            L10n.tr(
                "圧縮版（モデル約626 MB）を使用します。初回の準備には時間がかかります。作業領域の確保のため、実行時に%@以上の空き容量を確認します。",
                String(describing: ByteCountFormatter.string(
                    fromByteCount: SpeechStorage.requiredFreeBytes(for: self),
                    countStyle: .decimal,
                )),
            )
        }
    }
}

enum SpeechLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, japanese = "ja", english = "en", chinese = "zh", korean = "ko"
    case french = "fr", german = "de", spanish = "es", italian = "it", portuguese = "pt"

    var id: String { rawValue }
    var code: String? { self == .automatic ? nil : rawValue }
    var label: String {
        switch self {
        case .automatic: L10n.tr("自動判定")
        case .japanese: L10n.tr("日本語")
        case .english: L10n.tr("英語")
        case .chinese: L10n.tr("中国語")
        case .korean: L10n.tr("韓国語")
        case .french: L10n.tr("フランス語")
        case .german: L10n.tr("ドイツ語")
        case .spanish: L10n.tr("スペイン語")
        case .italian: L10n.tr("イタリア語")
        case .portuguese: L10n.tr("ポルトガル語")
        }
    }
}

struct SpeechPreferences: Codable, Equatable, Sendable {
    var model = SpeechModel.base
    var language = SpeechLanguage.japanese
    static let storageKey = "greminder.speech.v1"

    static func load(from defaults: UserDefaults = .standard) throws -> Self {
        guard let data = defaults.data(forKey: storageKey) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) throws {
        try defaults.set(JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}

struct SpeechSettingsClient: Sendable {
    var load: @Sendable () throws -> SpeechPreferences
    var save: @Sendable (SpeechPreferences) throws -> Void
}

extension SpeechSettingsClient: DependencyKey {
    static let liveValue = Self(load: { try SpeechPreferences.load() }, save: { try $0.save() })
    static let testValue = Self(load: { SpeechPreferences() }, save: { _ in })
}

extension DependencyValues {
    var speechSettings: SpeechSettingsClient {
        get { self[SpeechSettingsClient.self] }
        set { self[SpeechSettingsClient.self] = newValue }
    }
}

@Reducer
struct SpeechSettingsFeature {
    @ObservableState
    struct State: Equatable {
        var preferences = SpeechPreferences()
        var isLoaded = false
        var error: String?
    }

    enum Action {
        case load
        case modelChanged(SpeechModel)
        case languageChanged(SpeechLanguage)
    }

    @Dependency(\.speechSettings) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            do {
                switch action {
                case .load:
                    guard !state.isLoaded else { return .none }
                    state.preferences = try client.load()
                    state.isLoaded = true
                case let .modelChanged(model):
                    var updated = state.preferences
                    updated.model = model
                    try client.save(updated)
                    state.preferences = updated
                    state.isLoaded = true
                case let .languageChanged(language):
                    var updated = state.preferences
                    updated.language = language
                    try client.save(updated)
                    state.preferences = updated
                    state.isLoaded = true
                }
                state.error = nil
            } catch {
                state.error = L10n.tr("音声入力の設定を保存・読み込みできませんでした。%@", String(describing: error.localizedDescription))
            }
            return .none
        }
    }
}
