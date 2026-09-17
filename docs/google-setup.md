# Google Tasks接続の設定

初期状態ではログイン画面を表示します。クライアントID未設定時はログインボタンが無効になり、設定後にGoogle OAuthでログインできます。認証と初回のタスク読み込みが成功するとホーム画面に遷移します。認証のキャンセル・失敗時はログイン画面に留まり、再試行できます。次回起動時は保存済みの認証を復元し、サインアウトするとログイン画面に戻ります。

1. [Google Cloud Console](https://console.cloud.google.com/)でプロジェクトを作成し、Google Tasks APIを有効にします。
2. Google Auth Platformでアプリ情報・対象ユーザーを設定します。テスト中は利用するGoogleアカウントをテストユーザーとして登録します。必要な追加スコープは `https://www.googleapis.com/auth/tasks` です。
3. OAuthクライアントを作成します。Google Sign-In SDKでは**macOS向けもアプリケーションの種類は「iOS」**です。ターゲットごとに対応するBundle IDを登録してください。
   - iOS既定値: `com.example.greminder.ios`
   - macOS既定値: `com.example.greminder.macos`
   - ご自身のBundle IDに変える場合、`project.yml` の該当値も変更して `xcodegen generate` を実行します。
4. 用意済みの空の `Config/Local.xcconfig` に（ファイルがない場合は `Config/Local.xcconfig.example` をコピーして）、SDK別のクライアントIDとURLスキームを設定します。このファイルはGit管理から除外されています。

```xcconfig
GOOGLE_CLIENT_ID[sdk=iphoneos*] = IOS_CLIENT_ID.apps.googleusercontent.com
GOOGLE_CLIENT_ID[sdk=iphonesimulator*] = IOS_CLIENT_ID.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID[sdk=iphoneos*] = com.googleusercontent.apps.IOS_CLIENT_ID
GOOGLE_REVERSED_CLIENT_ID[sdk=iphonesimulator*] = com.googleusercontent.apps.IOS_CLIENT_ID

GOOGLE_CLIENT_ID[sdk=macosx*] = MAC_CLIENT_ID.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID[sdk=macosx*] = com.googleusercontent.apps.MAC_CLIENT_ID
```

5. Xcodeで各ターゲットのSigning & CapabilitiesからTeamを選択して署名します。Google認証を使う実機・MacではKeychain保存のためAppleの証明書による署名が必要です。macOSターゲットにはKeychain access groupを設定済みです。
6. Xcodeからアプリを起動し、ログイン画面のGoogleサインインを実行。Googleが表示するアクセス内容を確認して許可します。アカウントのホーム画面へ切り替わります。
7. 接続後、検証用リストで作成・編集・完了・予定日解除を確認し、Google Tasks側でも結果を確認してください。サンプルデータを自動転送する処理はありません。

このアプリには独自の認証バックエンドがないため、サーバー用WebクライアントIDやクライアントシークレットは不要です。クライアントIDは公開識別子です。アクセストークンやリフレッシュトークンを設定ファイルへ書く必要はありません。

`Build/greminder.app` はUI確認用のSwiftPMプレビューです。OAuthと署名を設定する場合は `Greminder.xcodeproj` のネイティブターゲットを使用してください。

## 公式資料

- [Google Sign-In: iOS/macOSの初期設定](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google Sign-In: SwiftUIでのURLコールバックと認証復元](https://developers.google.com/identity/sign-in/ios/sign-in)
- [Google API Objective-C Client for REST](https://github.com/google/google-api-objectivec-client-for-rest)
- [Google Tasksのリソース仕様](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks)

Google Tasks APIの `due` は予定日で、時刻の読み書きには対応しません。繰り返し・タグ・位置通知などを純正リマインダーと同じ同期項目として扱わない設計です。
