import ComposableArchitecture
import SwiftUI

struct NewListSheet: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Image(systemName: store.newListAppearance.symbol)
                            .font(.system(size: 36, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(AppTheme.tint(store.newListAppearance.tint), in: Circle())
                            .accessibilityHidden(true)
                        Spacer()
                    }.listRowBackground(Color.clear)
                    TextField(L10n.tr("リスト名"), text: $store.newListTitle)
                        .focused($titleFocused).onSubmit { store.send(.addList) }
                        .accessibilityIdentifier("new-list-title")
                }
                Section(L10n.tr("背景色")) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ListAppearance.colors, id: \.self) { color in
                            Button { store.newListAppearance.tint = color } label: {
                                Circle().fill(AppTheme.tint(color)).frame(width: 36, height: 36)
                                    .overlay {
                                        if store.newListAppearance.tint == color {
                                            Image(systemName: "checkmark").font(.body.bold())
                                                .foregroundStyle(color == "yellow" ? .black : .white)
                                        }
                                    }
                                    .frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(ListAppearance.colorLabel(color))
                                .accessibilityAddTraits(store.newListAppearance.tint == color ? .isSelected : [])
                                .accessibilityIdentifier("list-color-" + color)
                        }
                    }
                }
                Section(L10n.tr("アイコン")) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ListAppearance.symbols, id: \.self) { symbol in
                            Button { store.newListAppearance.symbol = symbol } label: {
                                Image(systemName: symbol).font(.title3)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(
                                        store.newListAppearance.symbol == symbol
                                            ? AppTheme.tint(store.newListAppearance.tint).opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10),
                                    )
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                        store.newListAppearance.symbol == symbol ? AppTheme
                                            .tint(store.newListAppearance.tint) : .clear,
                                        lineWidth: 2,
                                    ))
                            }.buttonStyle(.plain)
                                .accessibilityLabel(ListAppearance.symbolLabel(symbol))
                                .accessibilityAddTraits(store.newListAppearance.symbol == symbol ? .isSelected : [])
                                .accessibilityIdentifier("list-icon-" + symbol)
                        }
                    }
                }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .formStyle(.grouped)
            .disabled(store.isLoading)
            .navigationTitle(L10n.tr("新しいリスト"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("キャンセル")) { dismiss() }.disabled(store.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("追加")) { store.send(.addList) }
                        .disabled(store.newListTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store
                            .isLoading)
                        .accessibilityIdentifier("new-list-add")
                }
            }
            .interactiveDismissDisabled(store.isLoading)
        }
        #if os(macOS)
        .frame(width: 440, height: 550)
        #endif
    }
}
