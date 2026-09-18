# greminder

iOS / macOS ネイティブのSwiftUI製Google Tasksクライアント。選択された2案目を基に、純正リマインダーを実際に操作して確認した一覧内入力を実装しています。

## 起動

- Xcode 26.3以上、iOS / macOS 26以上。
- `Greminder.xcodeproj` を開き、`Greminder-iOS` または `Greminder-macOS` スキームを選んで実行。
- 初回起動はログイン画面。Google OAuthの設定後、ログインするとホーム画面へ遷移します。次回起動時には保存済みの認証を復元します。
- クライアントIDの入力先は `Config/Local.xcconfig`（Git管理対象外）。共有用の空テンプレートは `Config/Local.xcconfig.example` です。
- Debugビルドではデバッグ画面の「モックAPIを使用」でサンプルホームへ切り替えられます。設定未保存の場合、`--design-preview`を指定するとモックモードで起動します。
- Macだけを素早く試す場合は `zsh scripts/package-macos.sh`。`Build/greminder.app` を起動します。このプレビューバンドルはローカルの `.build` にも依存するため、配布にはXcodeターゲットを使用してください。
- プロジェクト定義を編集した場合は `xcodegen generate`。
- アプリアイコンは `Greminder/Resources/AppIcon.icon` をIcon Composerで編集。iOS / macOSで共用し、通常・ダーク表示とも白背景です。[アイコンと更新方法](design/AppIcon/README.md)

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

- **状態管理**: [TCA](https://github.com/pointfreeco/swift-composable-architecture) 1.23.1。`AppFeature` が入力、選択、保存キュー、AI提案、エラーを管理します。SwiftUIに残る状態はネイティブ入力フォーカスと、デバッグ画面の表示・一時的な操作状態です。
- **API**: [Google API Objective-C Client for REST](https://github.com/google/google-api-objectivec-client-for-rest) 5.4.0 の `GTLRTasksService` / 生成済みTasksクエリ。手書きURLSessionクライアントは使いません。
- **サンプルとテスト**: 同じ `executeQuery` を実行し、`service.testBlock` が `ticket.originalQuery` を受け、型・パラメーター・リクエストボディに応じてSDKの応答オブジェクトを返します。Googleへのネットワーク通信は行いません。
- **認証**: Google Sign-In 10.0.0。OAuth設定後は `fetcherAuthorizer` をサービスに渡し、testBlockなしでGoogleへ接続します。
- **ローカルAI**: [内部LocalLLMパッケージ](Packages/LocalLLM/README.md)のクライアントにモデル名とプロンプトを渡して非同期実行します。現在はApple Foundation Modelsに対応。ID・日付・文字数・操作種別を検証してから、通常入力と共通の保存キューに渡します。WhisperKitの音声処理は独立しています。
- **保存**: サンプルAPIの状態をApplication Support配下にJSONで原子的に保存。ライブ接続とサンプルは分離され、サンプルをGoogleに自動アップロードしません。
- **日付**: `TaskDay` は `yyyy-MM-dd` として扱い、Googleの値はUTC午前0時表記へ変換。予定時刻をAPIの対応機能として見せません。

## 音声入力と通知

マイクからWhisperKitで文字起こしし、結果を編集してタスクまたはAIの入力欄へ反映できます。設定で認識言語（自動判定・日本語・英語など）とモデル（Tiny / Base / Small / Large v3 Turbo）を切り替えます。設定は保存され、モデルは初回準備時に取得します。音声は端末内で処理します。

Large v3 TurboのSimulator実行はMac側に8 GB以上の空き容量が必要です。モデル本体約626 MBとは別にCore MLの作業ファイルが増えるため、準備・録音・文字起こしの前に容量を確認します。不足時はエラーを表示し、空きを増やして再試行できます。[クラッシュの調査と修正](docs/diagnostics/large-v3-turbo-simulator.md)、[実モデルのテスト手順](docs/QUALITY.md)を参照してください。

設定から端末通知を有効にし、予定日のあるタスクごとに通知日時を指定できます。期限超過した端末の通知日がGoogle Tasksの予定日と異なる場合は、一覧ダイアログで端末の日付を更新するか確認します。**Google Tasksの通知時刻は公式APIで取得・変更できないため、通知時刻そのものの同期はできません。** 詳細は[SPEC.md](docs/SPEC.md)に記載しています。

## アカウントメニュー

リスト一覧の右上に、検索ボタンと独立した円形アバターを表示します。アカウントアイコンは右端に配置し、ログイン画面・リスト詳細には表示しません。Googleプロフィールの写真を使い、写真がない場合や画像読込失敗時はイニシャル／人物アイコンを表示します。

クリックすると、現在の1アカウントの名前・メールとメニューをモーダルで表示します。Googleログインボタンは未ログイン時のみ表示し、ログイン済みのメニューは「設定」→「ログアウト」→「デバッグ」（Debugビルドのみ）の順に表示します。アカウント管理は設定画面からこのモーダルへ移動しました。編集・保存中はアカウント変更できません。モックAPIモード中でも明示的にGoogleへログイン／ログアウトできますが、タスクの接続先はモックのままです。

表示用プロフィールのみをUserDefaultsへ保存し、OAuth認証情報は引き続きGoogle Sign-In SDKのKeychain管理に任せます。[動作確認記録](docs/diagnostics/account-menu.md)

## 検証

デバッグ画面の「API接続先」→「モックAPIを使用」で通信先を切り替えます。オンでは通常と同じ`GoogleTasksService.executeQuery`を既存の`TasksTestBlockServer`で処理し、オフでは認証済みのGoogle Tasks APIを使用します。オフで未認証の場合はログイン画面へ戻り、モックのリクエストにフォールバックしません。Googleの認証情報はモックへの切替でも保持します。

Boolは`UserDefaults`の`greminder.api.usesMockAPI`へ保存し、次回起動時に復元します。通常の初期値はオフで、Releaseはこのデバッグ設定を使用しません。編集中・保存待ち・読込中・音声入力中・AI処理中は切替できず、接続先の読込に失敗した場合は元の接続先と設定を維持します。[切替と再起動の検証記録](docs/diagnostics/api-mode.md)

Debugビルドではリスト一覧右上のアカウントアイコンから「デバッグ」→「Push通知」を開けます。通知の許可をリクエストし、紐づけるタスクと待ち時間（5 / 15 / 30 / 60秒）を選んで「通知を予約」を押します。「状態を更新」で権限・予約状態を確認し、「テスト通知をキャンセル」で手動予約だけを取り消せます。

モックAPIモードで「サンプルホームを表示」をオフにすると、未ログイン時の通知タップを確認できます。サンプルの通知は無視され、ログイン操作を妨げません。編集取消の確認では、サンプルホームをオンにして「新規タスクを編集」から1,025文字以上のタイトルを入力し、通知を予約・タップします。保留中の通知と入力状態を確認し、「編集を取り消して閉じる」を押すと通知先の詳細が開きます。`--design-preview`で起動すると保存済みのGoogleセッションを自動復元せず、モックAPIのサンプルタスクをメモリ内で操作できます。保存済みのAPIモードはこの起動引数より優先されます。

通常のタスク通知も、タップすると紐づいているタスクの詳細を開きます。アプリが終了していた場合は、起動してタスクの読み込みが完了した後に遷移します。[フォアグラウンド・バックグラウンド・終了状態での検証記録](docs/diagnostics/notification-navigation.md)を参照してください。

手動予約と通常のタスク通知は、`LocalNotificationSystem.schedule` / `cancelRequests`、`ScheduledTaskNotification.makeRequest`、OSのdelegate、`AppFeature`の遷移処理を共用します。デバッグ専用の通知サービスは設けず、Releaseから除外するのは操作UIです。手動予約は別の識別子を使い、通常タスクの通知設定・予約に影響しません。APNs経由のリモートPush通知は対象外です。

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
