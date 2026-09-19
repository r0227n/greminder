import ComposableArchitecture
import SwiftUI

struct VoiceInputView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var store: StoreOf<VoiceFeature>
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heading
                if store.phase == .review {
                    review
                } else {
                    recording
                }
                if let error = store.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .accessibilityIdentifier("voice-error")
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .loadingOverlay(
            isPresented: isLoading,
            title: loadingTitle,
            message: store.phase == .preparing ? L10n.tr("初回はダウンロードと読み込みに時間がかかります。") : nil,
        )
        .accessibilityAction(.escape, close)
        #if os(iOS)
            .presentationDetents([store.phase == .review || dynamicTypeSize
                    .isAccessibilitySize ? .large : .height(store.error == nil ? 280 : 400)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(38)
            .presentationBackground(Color(uiColor: .secondarySystemGroupedBackground))
        #else
            .frame(width: 540, height: store.phase == .review ? 590 : 370)
            .background(AppTheme.sidebar)
            .onExitCommand(perform: close)
        #endif
    }

    private var heading: some View {
        VStack(spacing: 5) {
            if store.phase == .review {
                Text(L10n.tr("内容を確認"))
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }
            Text(Self.timecode(store.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.tr("録音時間、%@秒", String(describing: store.seconds)))
                .accessibilityIdentifier("voice-duration")
        }
    }

    private var recording: some View {
        VStack(spacing: 12) {
            VoiceWaveformView(levels: store.levels)
                .frame(height: 122)
                .padding(.top, 12)
            if store.phase == .idle {
                Button(L10n.tr("再試行")) { store.send(.prepare) }
                    .buttonStyle(.borderedProminent)
                    .frame(height: 60)
            } else {
                VoiceRecordButton(isRecording: store.phase == .recording) {
                    store.send(store.phase == .recording ? .stop : .record)
                }
                .disabled(![.ready, .recording].contains(store.phase))
            }
        }
    }

    private var review: some View {
        VStack(spacing: 20) {
            TextField(L10n.tr("文字起こし結果"), text: $store.transcript, axis: .vertical)
                .lineLimit(5 ... 12)
                .textFieldStyle(.plain)
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("voice-transcript")
            Text(L10n.tr("音声をこのデバイスで文字にします。内容を確認してから入力欄へ反映できます。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(store.destination == .task ? L10n.tr("タスクの入力欄に反映") : L10n.tr("AIの入力欄に反映")) {
                store.send(.accept)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.tr("録音し直す"), systemImage: "arrow.counterclockwise") { store.send(.record) }
                .buttonStyle(.borderless)
            Text("\(store.preferences.language.label) · \(store.preferences.model.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voice-configuration")
            Text(L10n.tr("WhisperKit · 音声は処理後に削除されます"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var isLoading: Bool {
        [.preparing, .requestingPermission, .transcribing].contains(store.phase)
    }

    private var loadingTitle: String {
        switch store.phase {
        case .transcribing: L10n.tr("文字起こし中…")
        case .requestingPermission: L10n.tr("マイクを準備中…")
        default: L10n.tr("準備中")
        }
    }

    private static func timecode(_ duration: TimeInterval) -> String {
        let hundredths = Int(max(0, duration) * 100)
        let seconds = hundredths / 100
        if seconds >= 3600 {
            return String(
                format: "%d:%02d:%02d.%02d",
                seconds / 3600,
                seconds / 60 % 60,
                seconds % 60,
                hundredths % 100,
            )
        }
        return String(format: "%02d:%02d.%02d", seconds / 60, seconds % 60, hundredths % 100)
    }
}

private struct VoiceRecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                RoundedRectangle(cornerRadius: isRecording ? 5 : 25)
                    .fill(.red)
                    .frame(width: isRecording ? 24 : 48, height: isRecording ? 24 : 48)
            }
            .frame(width: 60, height: 60)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? L10n.tr("停止して文字起こし") : L10n.tr("録音を開始"))
        .accessibilityIdentifier("voice-record")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isRecording)
    }
}

#Preview("Recording") {
    VoiceInputView(store: Store(initialState: VoiceFeature.State(
        phase: .recording,
        duration: 74.32,
        levels: (0 ..< 160).map { index in
            Float(abs(sin(Double(index) * 0.19)) * abs(sin(Double(index) * 0.043)))
        },
    )) { VoiceFeature() }, close: {})
        .preferredColorScheme(.dark)
}

#Preview("Review") {
    VoiceInputView(store: Store(initialState: VoiceFeature.State(
        phase: .review,
        transcript: "明日の朝、資料を確認する",
        duration: 4.32,
    )) { VoiceFeature() }, close: {})
}
