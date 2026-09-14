import ComposableArchitecture
import SwiftUI

struct VoiceInputView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<VoiceFeature>
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: store.phase == .recording ? "waveform" : "mic.circle")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(store.phase == .recording ? Color.red : AppTheme.blue)
                        .accessibilityHidden(true)
                    Text(title).font(.title2.bold())
                    Text(L10n.tr("音声をこのデバイスで文字にします。内容を確認してから入力欄へ反映できます。"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("\(store.preferences.language.label) · \(store.preferences.model.label)")
                        .font(.callout.weight(.medium)).accessibilityIdentifier("voice-configuration")

                    if let error = store.error {
                        Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    switch store.phase {
                    case .idle:
                        Text(L10n.tr("初回は音声モデルをダウンロードします。準備後の文字起こしにインターネット接続は不要です。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.tr("音声モデルを準備")) { store.send(.prepare) }.buttonStyle(.borderedProminent)
                    case .preparing:
                        ProgressView(L10n.tr("音声モデルを準備中…")).frame(maxWidth: .infinity)
                        Text(L10n.tr("初回はダウンロードと読み込みに時間がかかります。"))
                            .font(.caption).foregroundStyle(.secondary)
                    case .ready:
                        Button(L10n.tr("録音を開始"), systemImage: "mic.fill") { store.send(.record) }
                            .buttonStyle(.borderedProminent)
                        Text(L10n.tr("録音は最大60秒です。開始時にマイクの許可を確認します。"))
                            .font(.caption).foregroundStyle(.secondary)
                    case .requestingPermission:
                        ProgressView(L10n.tr("マイクを準備中…"))
                    case .recording:
                        Text(String(format: "0:%02d / 1:00", store.seconds)).monospacedDigit().font(.title3)
                            .accessibilityLabel(L10n.tr("録音中、%@秒", String(describing: store.seconds)))
                        Button(L10n.tr("停止して文字起こし"), systemImage: "stop.circle.fill") { store.send(.stop) }
                            .buttonStyle(.borderedProminent).tint(.red)
                    case .transcribing:
                        ProgressView(L10n.tr("文字起こし中…"))
                        Text(L10n.tr("マイクは停止しています。音声は外部へ送信しません。"))
                            .font(.caption).foregroundStyle(.secondary)
                    case .review:
                        TextField(L10n.tr("文字起こし結果"), text: $store.transcript, axis: .vertical)
                            .lineLimit(4 ... 10).textFieldStyle(.plain).padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("voice-transcript")
                        Button(store.destination == .task ? L10n.tr("タスクの入力欄に反映") : L10n.tr("AIの入力欄に反映")) {
                            store.send(.accept)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(L10n.tr("録音し直す"), systemImage: "arrow.counterclockwise") { store.send(.record) }
                            .buttonStyle(.borderless)
                    }
                    Text(L10n.tr("WhisperKit · 音声は処理後に削除されます"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .navigationTitle(L10n.tr("音声入力"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("キャンセル"), action: close) } }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .interactiveDismissDisabled(store.isBusy)
        #if os(macOS)
            .frame(width: 540, height: 590)
        #endif
    }

    private var title: String {
        switch store.phase {
        case .recording: L10n.tr("お話しください")
        case .transcribing: L10n.tr("音声を文字にしています")
        case .review: L10n.tr("内容を確認")
        default: store.destination == .task ? L10n.tr("声でタスクを入力") : L10n.tr("声でAIに指示")
        }
    }
}
