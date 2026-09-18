# Googleログイン後のクラッシュ

2026-09-17、iOSシミュレーターでGoogle認証後にタスクを取得する際、SIGABRTで終了。
クラッシュレポートと実行ログで、`__NSCFNumber` から `NSString` への強制変換失敗を確認。
スタックは `GTLRService` → `GTMSessionFetcher.authorizeRequest` →
`AuthSession.authorizeRequest(withArguments:)` → DictionaryのObjective-Cブリッジ。

Google Sign-In 9.0.0の `GIDEMMSupport` は、EMM設定がない場合にトークン応答の追加パラメーターを
そのまま返す。数値を含む辞書をGTMAppAuthの `[String: String]` として受け取るためクラッシュする。
9.2.0でもEMM設定なしの経路にはこの問題が残る。

Google Sign-Inを10.0.0へ更新。公式修正 #608 でEMM設定なしの場合も文字列へ変換する。
依存するAppAuthは3.0.0、GTMAppAuthは6.0.0に更新。SwiftPMとXcodeの両ロックファイルを更新。
認証や権限チェックを迂回する変更は行っていない。

- 公式リリースノート: https://developers.google.com/identity/sign-in/ios/release
- 修正ソース: https://github.com/google/GoogleSignIn-iOS/blob/10.0.0/GoogleSignIn/Sources/GIDEMMSupport.m

認証トークン・クライアントID・アカウント情報は本記録に含めない。

## 検証

- iPhone 17 Pro Max / iOS 26.2 Simulatorでビルド・起動に成功。
- 保存済みのGoogle認証を復元し、初回タスク取得後にホーム表示。「Google Tasks・接続済み」を確認。
- アプリ終了・再起動後もホーム表示を確認。
- `swift test --skip-update`: 95件中94件成功、音声実機能テスト1件は既定のスキップ、失敗なし。
- 今回のシミュレーターでの確認は認証復元経路。新規ログインの再同意およびライブタスクの書き込みは未実施。
