# 品質ゲート

## ローカルでの実行

Xcode 26.3（Swift 6.2.4）とmacOS 26で確認している。ツールはプロジェクトの`.tools`へインストールし、グローバル環境を変更しない。

```sh
bash scripts/install-quality-tools.sh
bash scripts/quality.sh format
bash scripts/quality.sh check
swift package resolve --force-resolved-versions
swift test
swift test --package-path Packages/LocalLLM
```

SwiftFormat 0.58.7 / SwiftLint 0.62.2を固定し、公式リリースのZIPをSHA-256検証してから展開する。設定は`.swiftformat`と`.swiftlint.yml`。SwiftFormatが整形を担当し、SwiftLintは明示した正しさ・Swift慣習のルールをstrictで検証する。ツール更新時はインストールスクリプトのバージョン・チェックサムと品質スクリプトのバージョン検証を同時に更新する。

## GitHub Actions

[quality.yml](../.github/workflows/quality.yml)はすべてのPR、main / developへのpush、手動実行で動く。macos-26ランナーのXcode 26.3を選択する。

| ジョブ | 条件 |
|---|---|
| Format and lint | 整形差分なし、lint違反なし、日英翻訳の欠落・引数不整合なし |
| macOS build and tests | 固定依存の解決、カバレッジ付きテスト、署名なしネイティブMacビルド |
| iOS simulator build | 同じPackage.resolved、署名なしSimulatorビルド、iOSホストテストのコンパイル |
| Quality Gate | 上記3ジョブがすべてsuccess。失敗・取消・skipは通さない |

Xcodeのワークスペースへルートの`Package.resolved`をコピーし、自動依存更新を無効にする。依存マクロの実行はCIで`-skipMacroValidation`を指定する。依存バージョン更新もPRで確認する。テストやサンプルのGoogle API呼び出しは公式SDKの`testBlock`へ渡し、認証情報はCIに不要。

GitHubへのpush後、Settings → Rules → Rulesets（またはBranches）でdevelop / mainに対するPRを必須にし、必須ステータスチェックとして`Quality Gate`を登録する。初回ワークフロー実行後にチェック名を選択できる。**このローカル作業ではGitHub上の実行・ブランチ保護設定は行っていない。** ワークフローだけでは管理者の直接pushやマージを禁止しない。

## 実音声テスト

標準テストは録音・モデルダウンロードを行わない。実WhisperKitの統合テストは任意で、合成した日本語音声を使う。初回はBaseモデルとトークナイザーの取得が必要。

```sh
say -v Kyoko -o /tmp/greminder-speech-fixture.aiff '明日、牛乳を買う。'
GREMINDER_TEST_AUDIO=/tmp/greminder-speech-fixture.aiff \
GREMINDER_TEST_MODEL_CACHE="$PWD/.build/whisper-models" \
swift test --filter WhisperIntegrationTests
```

標準テストの実行件数は末尾の最新検証結果を参照。この1件は環境変数なしではスキップする。実モデルテストはMacでBaseとLarge v3 Turbo圧縮版が成功している。Turboでは日本語固定と自動言語判定の両方を確認した。これはマイク経由の実音声、全言語、Tiny / Smallの認識精度を保証するテストではない。

Large v3 Turboを検証する場合は、上記環境変数に次を追加する。未取得なら約626 MBのモデルをダウンロードする。

```sh
GREMINDER_TEST_MODEL=openai_whisper-large-v3-v20240930_626MB
```

実行例:

```sh
GREMINDER_TEST_AUDIO=/tmp/greminder-speech-fixture.aiff \
GREMINDER_TEST_MODEL_CACHE="$PWD/.build/whisper-models" \
GREMINDER_TEST_MODEL=openai_whisper-large-v3-v20240930_626MB \
swift test --filter WhisperIntegrationTests
```

## iOS Simulatorの実モデル回帰テスト

ネイティブMacの成功だけではSimulatorのCore ML経路を検証できない。`Greminder-SpeechTests`はiOSアプリをホストとし、合成音声を同梱する。マイクは使わない。通常実行では容量のテスト3件が動き、モデルを使う2件は環境変数なしではスキップする。CIのiOSジョブは`build-for-testing`でアプリとこのテストターゲットをコンパイルする。

Large v3 Turboの回帰テストはSmallを準備してからTurboへ切り替え、日本語固定と自動判定の両方で「牛乳」「買」を認識することを検証する。最後にSmallの準備へ戻れることも確認する。Smallの認識精度はこのテストの成功条件には含めない。

```sh
TEST_RUNNER_GREMINDER_RUN_SPEECH_INTEGRATION=1 \
xcodebuild -project Greminder.xcodeproj -scheme Greminder-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
  -derivedDataPath DerivedData/ios -skipMacroValidation \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

初回はSmallとTurboのモデル・トークナイザーをダウンロードする。Turboの処理前には8 GB以上の空き容量を要求し、初回コンパイルでも容量を使うためMac側に十分な余裕を残す。XcodeBuildMCPでは`test_sim`の`testRunnerEnv`に`{"GREMINDER_RUN_SPEECH_INTEGRATION":"1"}`を指定する。

2026-09-14、Xcode 26.3 / iOS 26.2で容量不足時のクラッシュと、空き確保・予防チェック追加後のTurboの文字起こし成功を確認した。[原因・証跡と制約](diagnostics/large-v3-turbo-simulator.md)を参照。

Smallは同じ合成音声でSimulatorの認識結果が不一致になる別の問題を検出した。ネイティブMacでは同じモデル・音声のテストが成功する。失敗条件を残した`testSmallJapaneseTranscriptionDiagnostic`は`TEST_RUNNER_GREMINDER_RUN_SMALL_DIAGNOSTICS=1`で有効にする。この診断は現在Simulatorで失敗するため、Turboのクラッシュ回帰テストと区別して扱う。

## リスト外観・表示言語の回帰確認

`ListAppearanceTests`は公式SDKのtestBlock経由で作成・再取得・保存先の再生成後も外観を保持すること、アカウント分離、通信失敗からの再試行を確認する。`LocalizationTests`は日英のバンドルリソース・引数順序・表示言語と音声認識言語の独立性を確認する。翻訳260キーの整合性は`python3 scripts/check-localizations.py`でも実行できる。

Simulator（iPhone 17 Pro Max / iOS 26.2）で英語への即時変更、再起動後の設定保持、日本語への切り替え、外観選択・作成・再読み込みを確認。最終のiOS Simulator / macOSビルド、41件中40件成功・1件スキップ、formatter / linterと253キーの翻訳チェックが成功した。実Googleアカウント、iPad実画面、macOSの新規画面の実操作、全Dynamic Typeサイズは未検証。

- [英語の設定](diagnostics/settings-english.jpg)
- [日本語の設定](diagnostics/settings-japanese.jpg)
- [アイコンと背景色の選択](diagnostics/new-list-appearance-english.jpg)
- [再読み込み後の外観](diagnostics/list-appearance-reloaded.jpg)

### AI入力欄の表示切り替え（2026-09-14）

ツールバーの輝きアイコンを押し、入力欄・キーボードの非表示と斜線付きアイコンへの変更、再表示時の入力文字の保持をiPhone 17 Pro Max / iOS 26.2で確認した。iOS SimulatorとmacOSのビルド、formatter / linter、255キーの翻訳チェックが成功した。今回の表示変更ではユニットテストを再実行していない。

### ホーム検索（2026-09-14）

検索UIをホーム下部に移動。全リスト・完了タスク・メモの検索、通常一覧との分離、結果から所属リスト・詳細への遷移についてAppFeatureTests 12件が成功。iOS Simulator / macOSビルド、formatter / linter、257キーの翻訳チェックが成功した。Simulatorで検索欄内のクリア、欄外の×によるキーボード終了と検索語の保持、タスク一覧に検索UIがないことを確認した。

### 内部LocalLLMパッケージ（2026-09-14）

`Packages/LocalLLM`を整形・lint・CIの対象に追加した。通常CIはパッケージ単体テストを別途実行する。モデルを必要とするテストは通常スキップし、`LOCAL_LLM_INTEGRATION=1 swift test --package-path Packages/LocalLLM`で明示的に実行できる。

最終検証では実Appleモデルによるテキスト生成と構造化タスク生成を含むパッケージ9件が成功。日付を要求しない合成指示で当日を補う出力を検出し、基準日と予定日の区別を内部指示へ追加して同じ検証が成功した。これは個別のプロンプトでの確認であり、自然言語の意味解釈を常に保証するものではない。

アプリのテスト46件中45件成功、既存の実WhisperKit任意テスト1件スキップ。ID・日付・重複対象の検証と、キャンセル後に遅れた結果やエラーが表示されないことを含む。固定依存の解決、iOS Simulatorビルド・起動、macOSビルド、SwiftFormat / SwiftLint、260キーの翻訳チェックが成功した。GitHub Actions自体は未実行。

### SOLID / SSOTの全体レビューとリネーム（2026-09-14）

アプリ77件中76件成功・実WhisperKit任意テスト1件スキップ、内部LocalLLMパッケージ9件中8件成功・実Appleモデル任意テスト1件スキップ。両方とも失敗0。直前の46件から、非同期競合、削除と保存順序、アカウント切り替え失敗、通知の識別子移行・直列化、共有設定、日付検証について31件の回帰テストを追加した。

iOSのビルド・起動、iOSホストテストのコンパイル、macOSネイティブターゲットの署名なしビルド、SwiftFormat / SwiftLint strictと日英翻訳261キーの整合性チェックが成功した。生成された両OSのアプリは表示名と実行ファイル名が`greminder`。Simulatorでは詳細の通知ON/OFF、保存済み時刻の復元、時刻ホイール表示、日本語→英語→日本語の即時切り替えを確認した。

実モデルの再実行・実Google OAuth・GitHub Actionsのリモート実行は今回含まない。指摘、破壊的変更、残る制約は[CODE_REVIEW.md](CODE_REVIEW.md)に記録。
