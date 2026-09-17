import ComposableArchitecture
import GoogleSignInSwift
import SwiftUI

struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 20) {
                    Image(systemName: "checklist")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 104, height: 104)
                        .background(AppTheme.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 28))
                        .accessibilityHidden(true)
                    Text("greminder")
                        .font(.largeTitle.bold())
                    Text(L10n.tr("今日のやることを、ひとつずつ。"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.tr("Googleアカウントでログインして、Google Tasksのリストとタスクを管理しましょう。"))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 18) {
                    if store.usesMockAPI {
                        Button(L10n.tr("サンプルホームを開く")) { store.send(.connect) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canSwitchAccount)
                            .accessibilityIdentifier("mock-sign-in")
                    } else {
                        GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light) {
                            store.send(.connect)
                        }
                        .frame(maxWidth: 320)
                        .disabled(store.isLoading || !store.canSwitchAccount || !TasksEnvironment.isConfigured)
                        .accessibilityIdentifier("google-sign-in")
                    }

                    if store.isLoading {
                        ProgressView(L10n.tr("アカウントを確認中…"))
                            .accessibilityIdentifier("login-progress")
                    } else if !store.usesMockAPI, !TasksEnvironment.isConfigured {
                        Text(L10n.tr("Googleログインは準備中です。設定が完了すると利用できます。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if let error = store.error {
                        Text(error)
                            .font(.callout).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("login-error")
                    }
                }

                #if DEBUG
                    DebugToolsButton(store: store)
                #endif

                Text(L10n.tr("ログイン時に、Google Tasksへのアクセスを許可してください。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 28)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surface)
        .accessibilityIdentifier("login-screen")
    }
}

#Preview {
    LoginView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
