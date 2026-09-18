import ComposableArchitecture
import GoogleSignInSwift
import SwiftUI

struct CircleAvatar: View {
    var profile: GoogleAccountProfile?
    var size: CGFloat = 34

    var body: some View {
        AsyncImage(url: profile?.imageURL) { phase in
            if let image = phase.image {
                image.resizable().renderingMode(.original).scaledToFill()
            } else {
                ZStack {
                    AppTheme.blue.opacity(0.12)
                    if let initial = profile?.displayName.first {
                        Text(String(initial).uppercased())
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(AppTheme.blue)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.48)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Concrete colors keep their opacity during native toolbar transitions.
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct AccountMenuButton: View {
    @Bindable var store: StoreOf<AppFeature>
    let source: String

    var body: some View {
        Button { store.accountMenuSource = source } label: {
            CircleAvatar(profile: store.signedInAccounts.first)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(AvatarButtonStyle())
        .accessibilityLabel(L10n.tr("アカウントメニュー"))
        .accessibilityIdentifier("account-menu-open")
        .help(L10n.tr("アカウントメニュー"))
    }
}

/// Keep the profile's colors unchanged when opening or closing account management.
private struct AvatarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct AccountMenuView: View {
    private enum Destination: String, Identifiable {
        case settings
        #if DEBUG
            case debug
        #endif
        var id: String { rawValue }
    }

    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var destination: Destination?

    private var panelBackground: Color {
        colorScheme == .dark ? Color(red: 0.12, green: 0.14, blue: 0.17)
            : Color(red: 0.94, green: 0.96, blue: 0.99)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accounts
                    if store.usesMockAPI {
                        Label(L10n.tr("サンプルデータ"), systemImage: "externaldrive")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.signedInAccounts.isEmpty { signInAction }
                    if store.isLoading { ProgressView(L10n.tr("アカウントを確認中…")) }
                    if let error = store.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !store.canSwitchAccount, !store.isLoading {
                        Text(L10n.tr("編集中・保存中の操作を完了してからアカウントを変更してください。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        Button { destination = .settings } label: {
                            menuLabel("設定", symbol: "gearshape")
                        }
                        .accessibilityIdentifier("account-settings-open")
                        if !store.signedInAccounts.isEmpty {
                            Divider().padding(.horizontal, 16)
                            Button { store.send(.signOutAccount) } label: {
                                menuLabel("ログアウト", symbol: "rectangle.portrait.and.arrow.right", showsDisclosure: false)
                            }
                            .disabled(!store.canSwitchAccount)
                            .accessibilityIdentifier("account-sign-out")
                        }
                        #if DEBUG
                            Divider().padding(.horizontal, 16)
                            Button { destination = .debug } label: {
                                menuLabel("デバッグ", symbol: "ladybug")
                            }
                            .accessibilityIdentifier("debug-tools-open")
                        #endif
                    }
                    .buttonStyle(.plain)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity)
            .background(panelBackground)
            .navigationTitle(L10n.tr("アカウント"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("閉じる")) { dismiss() }
                        .accessibilityIdentifier("account-menu-close")
                }
            }
        }
        .presentationBackground(panelBackground)
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            .onExitCommand { dismiss() }
        #endif
            .sheet(item: $destination) { destination in
                switch destination {
                case .settings: SettingsView(store: store)
                #if DEBUG
                    case .debug: DebugToolsView(store: store)
                #endif
                }
            }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("ログイン中のアカウント"))
                .font(.caption).foregroundStyle(.secondary)
            if store.signedInAccounts.isEmpty {
                HStack(spacing: 12) {
                    CircleAvatar(size: 52)
                    Text(L10n.tr("ログインしていません"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(store.signedInAccounts) { account in
                HStack(spacing: 12) {
                    CircleAvatar(profile: account, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName).font(.headline)
                        if !account.name.isEmpty {
                            Text(account.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.blue)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("signed-in-account")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }

    private var signInAction: some View {
        VStack(spacing: 12) {
            GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light) {
                store.send(.signInAccount)
            }
            .disabled(!store.canSwitchAccount || !TasksEnvironment.isConfigured)
            .accessibilityIdentifier("account-sign-in")
            if !TasksEnvironment.isConfigured {
                Text(L10n.tr("Googleログインは準備中です。設定が完了すると利用できます。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func menuLabel(_ title: String, symbol: String, showsDisclosure: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24)
            Text(L10n.tr(title))
            Spacer()
            if showsDisclosure {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
