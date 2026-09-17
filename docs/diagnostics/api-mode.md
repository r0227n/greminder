# API接続先の切替と永続化（2026-09-17）

デバッグ画面の「API接続先」に「モックAPIを使用」を追加。

- オン：`GoogleTasksService`が発行したSDKクエリを、既存の`TasksTestBlockServer`の`testBlock`で処理。取得・追加・更新・削除の通常処理を共用する。
- オフ：Google OAuthの接続を使用。未認証ならログイン画面を表示し、モックへフォールバックしない。モックへの切替はGoogleのサインアウトを行わない。
- `TasksEnvironment`が接続先の読込に成功してから通信先とBoolを更新。`TasksAPISettings`が`UserDefaults`キー`greminder.api.usesMockAPI`を保存・復元する。読込失敗時には両方を維持する。
- 切替中や編集・保存待ち・音声入力・AI処理がある間はトグルを無効化する。成功後は以前の検索・選択・通知遷移状態をリセットして、新しい一覧を表示する。
- Debugの通常初期値はオフ。設定が未保存の`--design-preview`起動ではオン。保存済みの値を優先し、Releaseの初期化は常に実APIモードとする。

## Simulatorでの操作確認

iPhone 17 Pro Max / iOS 26.2、Debugビルド、`--design-preview`で実施。

1. デバッグ画面でモックをオン→オフ。説明がGoogle Tasks APIへ変わり、背景がログイン画面へ切り替わることを確認。
2. アプリを停止・再起動。ログイン画面が表示され、トグルのオフが保持されることを確認。
3. オフ→オン。既存サンプルタスクが表示されることを確認。
4. 再度停止・再起動。サンプルホームとオンの設定が復元されることを確認。

[実APIモード](api-mode-live.jpg) / [再起動後のモックモード](api-mode-mock-restored.jpg)

実Googleアカウントへのログイン・CRUDは今回の実操作では実行していない。認証済み接続とモックの振り分けは、独立したSDKのtestBlockサーバーを使う自動テストで確認した。

## 自動テスト

`Tests/TasksAPIModeTests.swift`：Swift Testingの8テスト（14ケース）成功。

- Boolのtrue/falseの永続化・別インスタンスからの復元。
- 保存済みモックモードでOAuthを呼ばず、SDKのtestBlock経由でCRUDすること。
- 通信先を往復し、モックの書込みが実接続へ流れず、実接続の書込みがモックへ流れないこと。
- 切替先の読込失敗で通信先・保存値が変更されないこと（両方向）。
- 未認証の実APIモードでモックのリクエストを発行しないこと。
- Reducerの切替成功・失敗・処理中の拒否。

全体：`swift test --skip-update`成功。XCTest94件（93成功・任意の実音声テスト1件スキップ）、Swift Testing20テスト成功。iOS Simulatorビルド・起動、翻訳313キー、SwiftFormat、SwiftLint、`git diff --check`も成功。
