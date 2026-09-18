import ComposableArchitecture
import GoogleSignIn
import SwiftUI

public struct GreminderRootView: View {
    @Environment(\.locale) private var locale
    @State private var store: StoreOf<AppFeature>
    @Environment(\.scenePhase) private var scenePhase

    private var showsDetailModal: Bool {
        #if os(iOS)
            store.showsTaskDetails
        #else
            false
        #endif
    }

    public init() {
        var state = AppFeature.State()
        #if DEBUG
            state.usesMockAPI = TasksAPISettings.initialUsesMockAPI
            state.showsSampleTasks = state.usesMockAPI
        #endif
        _store = State(initialValue: Store(initialState: state) { AppFeature() })
    }

    private var showsHome: Bool { store.canNavigateToTasks }

    public var body: some View {
        @Bindable var store = store
        // Keep lifecycle tasks and notification subscriptions alive across authentication changes.
        ZStack {
            if showsHome {
                home
            } else {
                LoginView(store: store)
            }
        }
        .sheet(isPresented: Binding(
            get: { store.accountMenuSource != nil },
            set: { if !$0 { store.accountMenuSource = nil } },
        ), onDismiss: { store.send(.notificationPresentationDismissed) }) {
            AccountMenuView(store: store)
        }
        #if DEBUG
        .sheet(isPresented: $store.showsDebug, onDismiss: { store.send(.notificationPresentationDismissed) }) {
                DebugToolsView(store: store)
            }
        #endif
            .tint(AppTheme.blue)
            .task { await store.send(.appeared).finish() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                // macOS can receive a share while its window is already active.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    store.send(.checkSharedTasks)
                }
            }
            .task {
                for await key in LocalNotificationSystem.shared.responses.stream {
                    store.send(.notificationTapped(key))
                }
            }
            .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
            .onChange(of: showsHome) { _, _ in store.accountMenuSource = nil }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, store.showsVoice { store.send(.closeVoice) }
                if phase == .active, showsHome { store.send(.foreground) }
            }
            .environment(\.locale, Locale(identifier: L10n.identifier(for: store.displayLanguage)))
        #if os(macOS)
            .frame(minWidth: showsHome ? (store.showsTaskDetails ? 1080 : 780) : 480, minHeight: 600)
        #endif
    }

    @ViewBuilder
    private var home: some View {
        @Bindable var store = store
        NavigationSplitView(preferredCompactColumn: $store.compactColumn) {
            TaskSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 350)
        } detail: {
            TaskDetailLayout(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { store.showsSettings && !showsDetailModal },
            set: { if !$0 { store.showsSettings = false } },
        ), onDismiss: { store.send(.notificationPresentationDismissed) }) { SettingsView(store: store) }
        .sheet(isPresented: $store.showsNewList, onDismiss: { store.send(.notificationPresentationDismissed) }) {
            NewListSheet(store: store)
        }
        .sheet(
            isPresented: Binding(get: { store.showsVoice }, set: { if !$0 { store.send(.closeVoice) } }),
            onDismiss: { store.send(.notificationPresentationDismissed) },
        ) {
            VoiceInputView(store: store.scope(state: \.voice, action: \.voice)) { store.send(.closeVoice) }
        }
        .sheet(isPresented: Binding(
            get: {
                #if DEBUG
                    if store.showsDebug { return false }
                #endif
                return store.accountMenuSource == nil && store.pendingNotificationKey == nil && !store.notifications
                    .conflicts.isEmpty && !store
                    .showsSettings && !store.showsVoice && !store
                    .showsNewList && !showsDetailModal
            },
            set: { _ in },
        ), onDismiss: { store.send(.notificationPresentationDismissed) }) {
            NotificationConflictView(store: store.scope(state: \.notifications, action: \.notifications))
        }
        .confirmationDialog(L10n.tr("このタスクを削除しますか？サブタスクも削除されます。"), isPresented: Binding(
            get: { store.deleteCandidate != nil && !showsDetailModal },
            set: { if !$0 { store.deleteCandidate = nil } },
        ), titleVisibility: .visible) {
            Button(L10n.tr("削除"), role: .destructive) { store.send(.confirmDelete) }
        }
    }
}

struct TaskSidebar: View {
    @Environment(\.locale) private var locale
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var searchFocused: Bool
    let smartLists: [TaskSelection] = [.today, .scheduled, .all, .completed]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if store.showsSearch, !store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HomeSearchResults(store: store)
                        .padding(16).padding(.bottom, 88)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(smartLists, id: \.self) { item in
                                Button { store.send(.select(item)) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Image(systemName: item.symbol).font(.system(size: 20, weight: .semibold))
                                            Spacer()
                                            Text(
                                                "\(store.snapshot.tasks(for: item, today: store.today).count)",
                                            )
                                            .font(.system(size: 23, weight: .bold, design: .rounded))
                                        }
                                        Text(item.title).font(.system(size: 15, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(13)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppTheme.tint(item), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(
                                        .primary.opacity(store.selection == item ? 0.14 : 0),
                                        lineWidth: 2,
                                    ))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    L10n.tr(
                                        "%@、%@件",
                                        String(describing: item.title),
                                        String(describing: store.snapshot.tasks(for: item, today: store.today).count),
                                    ),
                                )
                            }
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Google Tasks").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(
                                    .horizontal,
                                    8,
                                ).padding(.bottom, 7)
                            ForEach(store.snapshot.lists) { list in
                                Button { store.send(.select(.list(list.id))) } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: list.symbol).font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.white).frame(width: 31, height: 31)
                                            .background(AppTheme.tint(list.tint), in: Circle())
                                        Text(list.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(
                                            "\(store.snapshot.tasks.count(where: { $0.listID == list.id && !$0.isCompleted }))",
                                        )
                                        .font(.system(size: 14)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 9)
                                    .background(
                                        store.selection == .list(list.id) ? AppTheme.subtle : .clear,
                                        in: RoundedRectangle(cornerRadius: 9),
                                    )
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 88)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                FloatingAddButton(title: L10n.tr("リストを追加"), color: AppTheme.blue, identifier: "list-add-fab") {
                    store.showsNewList = true
                }.padding(20)
            }
            if store.showsSearch {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.tr("タスクを検索"), text: $store.search)
                            .focused($searchFocused)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("home-search-input")
                        if !store.search.isEmpty {
                            Button { store.search = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("検索をクリア"))
                            .accessibilityIdentifier("home-search-clear")
                        }
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.08)))
                    Button { searchFocused = false } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(AppTheme.surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("キーボードを閉じる"))
                    .accessibilityIdentifier("home-search-dismiss-keyboard")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(AppTheme.sidebar)
        .navigationTitle(L10n.tr("リスト"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.showsSearch.toggle()
                    searchFocused = store.showsSearch
                    if !store.showsSearch { store.search = "" }
                } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help(L10n.tr("タスクを検索"))
                    .accessibilityLabel(L10n.tr("タスクを検索"))
                    .accessibilityIdentifier("home-search-toggle")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { AccountMenuButton(store: store, source: "sidebar") }
                .sharedBackgroundVisibility(.hidden)
        }
        .onDisappear { searchFocused = false }
    }
}

struct HomeSearchResults: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if store.searchResults.isEmpty {
                Text(L10n.tr("一致するタスクがありません"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            ForEach(store.searchResults) { task in
                Button { store.send(.openSearchResult(task.id)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(AppTheme
                                .tint(store.snapshot.lists.first { $0.id == task.listID }?.tint ?? "blue"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).foregroundStyle(.primary).lineLimit(2)
                            Text(store.snapshot.lists.first { $0.id == task.listID }?.title ?? L10n.tr("リスト"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-search-result-\(task.id)")
                Divider()
            }
        }
    }
}
