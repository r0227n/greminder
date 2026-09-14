# greminder

iOS / macOS ネイティブのSwiftUI製Google Tasksクライアント。選択された2案目を基に、純正リマインダーを実際に操作して確認した一覧内入力を実装しています。

## 起動

- Xcode 26.3以上、iOS / macOS 26以上。
- `Greminder.xcodeproj` を開き、`Greminder-iOS` または `Greminder-macOS` スキームを選んで実行。
- 初回起動はサンプルモード。Googleの認証情報なしで動きます。
- Macだけを素早く試す場合は `zsh scripts/package-macos.sh`。`Build/greminder.app` を起動します。このプレビューバンドルはローカルの `.build` にも依存するため、配布にはXcodeターゲットを使用してください。
- プロジェクト定義を編集した場合は `xcodegen generate`。

Google連携は [設定手順](docs/google-setup.md) を参照してください。

画面・操作・対応範囲は [SPEC.md](docs/SPEC.md)、構成とデータの流れは [ARCHITECTURE.md](docs/ARCHITECTURE.md)、実画面の確認結果は [design-qa.md](design-qa.md) にまとめています。

## 入力と操作

- Mac: 余白をダブルクリック、＋、または⌘Nで新規入力。
- iOS: 余白をタップ、または＋で新規入力。
- タイトルを入力してEnter /「次へ」: 保存して、直後の行で続けて入力。
- 空欄のEnter /「次へ」: 空タスクを保存せずに入力を終了。
- 既存タイトルをクリック: 一覧内でタイトル・メモ・予定日を編集。
- 既存タイトルのEnter: 修正を保存し、その直下に新規入力行。
- MacのEsc: 未確定の編集を閉じる。
- 行のコンテキストメニュー: 直下への追加、サブタスク追加、削除。
- ⓘから右側の詳細パネルでタイトル・メモ・予定日・通知・サブタスクを編集。iOSではモーダルで表示します。
- 丸い完了ボタン、スマートリスト、リスト切り替え、検索、新規リスト作成。
- リストとタスクの追加は右下のFAB。タスク画面の見出し・操作アイコン・FABはリスト色に揃え、iOS詳細の通常文字は黒系の標準文字色にします。
- 新規リストは12種類のアイコンと12色の背景色から選択。外観は端末内にアカウント・リスト単位で保存。
- 設定の「表示言語」で日本語・English・システム設定を切り替え。選択は保存され、すぐに画面へ反映。

AI入力は下部にあります。自然文から追加・予定日変更・完了の提案を作り、内容を確認して適用します。「入力例を試す」はAIを呼ばずにサンプル提案を表示する明示的なデモです。

## 実装

- **状態管理**: [TCA](https://github.com/pointfreeco/swift-composable-architecture) 1.23.1。`AppFeature` が入力、選択、保存キュー、AI提案、エラーを管理します。SwiftUIに残る状態はネイティブ入力フォーカスだけです。
- **API**: [Google API Objective-C Client for REST](https://github.com/google/google-api-objectivec-client-for-rest) 5.4.0 の `GTLRTasksService` / 生成済みTasksクエリ。手書きURLSessionクライアントは使いません。
- **サンプルとテスト**: 同じ `executeQuery` を実行し、`service.testBlock` が `ticket.originalQuery` を受け、型・パラメーター・リクエストボディに応じてSDKの応答オブジェクトを返します。Googleへのネットワーク通信は行いません。
- **認証**: Google Sign-In 9.0.0。OAuth設定後は `fetcherAuthorizer` をサービスに渡し、testBlockなしでGoogleへ接続します。
- **ローカルAI**: [内部LocalLLMパッケージ](Packages/LocalLLM/README.md)のクライアントにモデル名とプロンプトを渡して非同期実行します。現在はApple Foundation Modelsに対応。ID・日付・文字数・操作種別を検証してから、通常入力と共通の保存キューに渡します。WhisperKitの音声処理は独立しています。
- **保存**: サンプルAPIの状態をApplication Support配下にJSONで原子的に保存。ライブ接続とサンプルは分離され、サンプルをGoogleに自動アップロードしません。
- **日付**: `TaskDay` は `yyyy-MM-dd` として扱い、Googleの値はUTC午前0時表記へ変換。予定時刻をAPIの対応機能として見せません。

## 音声入力と通知

マイクからWhisperKitで文字起こしし、結果を編集してタスクまたはAIの入力欄へ反映できます。設定で認識言語（自動判定・日本語・英語など）とモデル（Tiny / Base / Small / Large v3 Turbo）を切り替えます。設定は保存され、モデルは初回準備時に取得します。音声は端末内で処理します。

Large v3 TurboのSimulator実行はMac側に8 GB以上の空き容量が必要です。モデル本体約626 MBとは別にCore MLの作業ファイルが増えるため、準備・録音・文字起こしの前に容量を確認します。不足時はエラーを表示し、空きを増やして再試行できます。[クラッシュの調査と修正](docs/diagnostics/large-v3-turbo-simulator.md)、[実モデルのテスト手順](docs/QUALITY.md)を参照してください。

設定から端末通知を有効にし、予定日のあるタスクごとに通知日時を指定できます。期限超過した端末の通知日がGoogle Tasksの予定日と異なる場合は、一覧ダイアログで端末の日付を更新するか確認します。**Google Tasksの通知時刻は公式APIで取得・変更できないため、通知時刻そのものの同期はできません。** 詳細は[SPEC.md](docs/SPEC.md)に記載しています。

## 検証

```sh
bash scripts/install-quality-tools.sh
bash scripts/quality.sh check
swift test
```

`TestStore` と実際のSDKの `testBlock` を組み合わせ、Enter連続入力、既存行編集、保存失敗・再試行、AI親子追加、古くなった提案の拒否、ページング、完了タスク取得、日付解除のJSON null、条件付き更新を検証します。

GitHub Actionsはフォーマット、lint、macOSテスト・ビルド、iOS Simulatorビルドの全成功を`Quality Gate`で要求します。ブランチ保護への登録は[QUALITY.md](docs/QUALITY.md)を参照してください。

## 現在の範囲

これは動作する初期実装です。Google OAuth未設定のため、実アカウントでの認証・同期は未検証です。ライブAPIの変更は接続が必要です。保存待ちキューはアプリ起動中のメモリに保持され、失敗した入力は画面から再試行できますが、終了・クラッシュをまたぐ永続的なオフライン送信キューは未実装です。

Googleの作成リクエストには汎用的な冪等キーがないため、通信断で結果が不明な新規作成を自動再送しません。明示的な再試行で重複する可能性の扱い、競合を解決するUI、ライブキャッシュ、リスト間移動、並べ替え、繰り返し・タグは今後の実装範囲です。

TCA 1.23.1はインストール済みSwift 6.2.4で動作する版として固定しています。依存グラフは `Package.resolved` に記録しています。
# greminder
