import ComposableArchitecture
import SwiftUI

struct AIComposerView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var inputFocused: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.tint)
                TextField(L10n.tr("AIに頼む…"), text: $store.aiText, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1 ... 3).textFieldStyle(.plain)
                    .font(.system(size: 15)).submitLabel(.send)
                    .onSubmit { store.send(.askAI) }
                    .accessibilityLabel(L10n.tr("AIへの指示"))
                Button { store.send(.openVoice(.ai)) } label: {
                    Image(systemName: "mic").font(.system(size: 19)).frame(width: 32, height: 32)
                }.buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityLabel(L10n.tr("音声でAIに指示")).disabled(store.isThinking || store.showsVoice)
                if store.isThinking {
                    Button { store.send(.cancelProposal) } label: { ProgressView().controlSize(.small).frame(
                        width: 30,
                        height: 30,
                    ) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.tr("AIの処理を中止"))
                } else {
                    Button { store.send(.askAI) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 31)).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.aiText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store
                        .aiUnavailable != nil)
                    .accessibilityLabel(L10n.tr("AIに指示を送信"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            HStack(spacing: 8) {
                Text(store.isExample ? L10n.tr("入力例のプレビュー・AI未使用") : store
                    .aiUnavailable != nil ? L10n.tr("端末内AIは現在利用できません") : L10n.tr("AIの処理はこのデバイス内"))
                    .foregroundStyle(.secondary)
                if store.proposals.isEmpty {
                    Button(L10n.tr("入力例を試す")) { store.send(.showExample) }.buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(store.isThinking || store.snapshot.lists.isEmpty)
                }
            }.font(.system(size: 11))
        }
        .onDisappear { inputFocused = false }
        .onChange(of: store.showsVoice) { _, visible in
            inputFocused = !visible && store.voice.destination == .ai
        }
    }
}

struct ProposalPreview: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Divider().padding(.bottom, 8)
            Text(store.proposals.allSatisfy { $0.operation == .add } ? L10n.tr("追加するタスク") : L10n.tr("変更するタスク"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(store.proposals) { proposal in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: proposal.operation == .complete ? "checkmark.circle" : "circle")
                            .font(.system(size: 22, weight: .ultraLight)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(proposal.task.title).font(.system(size: 16, weight: .medium))
                            Text([
                                proposal.task.due?.label,
                                store.snapshot.lists.first { $0.id == proposal.task.listID }?.title,
                            ].compactMap(\.self).joined(separator: " · "))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(proposal.subtasks.enumerated()), id: \.offset) { _, title in
                        HStack(spacing: 12) {
                            Image(systemName: "circle").font(.system(size: 21, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                            Text(title).font(.system(size: 15))
                        }.padding(.leading, 32)
                    }
                }
            }
            actionLayout {
                Button { store.send(.applyProposal) } label: {
                    Text(L10n.tr(
                        "%@件を%@",
                        String(describing: store.proposedCount),
                        String(describing: store.proposals.allSatisfy { $0.operation == .add } ? L10n.tr("追加") : L10n
                            .tr("変更")),
                    ))
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 10)
                    .frame(minWidth: 125)
                    #if os(iOS)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    #endif
                        .foregroundStyle(.white).background(.tint, in: Capsule())
                }.buttonStyle(.plain).disabled(!store.pending.isEmpty)
                Button(L10n.tr("キャンセル")) { store.send(.cancelProposal) }.buttonStyle(.plain).font(.system(size: 13))
                    .foregroundStyle(.secondary)
                #if os(iOS)
                    .frame(maxWidth: .infinity, minHeight: 44)
                #endif
            }.padding(.top, 5)
        }
    }

    private var actionLayout: AnyLayout {
        #if os(macOS)
            AnyLayout(HStackLayout(spacing: 20))
        #else
            AnyLayout(VStackLayout(spacing: 12))
        #endif
    }
}
