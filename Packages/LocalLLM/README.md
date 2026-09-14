# LocalLLM

iOS 26 / macOS 26以上向けの内部Swift Package。Swift 6のSendableチェックを有効にする。外部パッケージ依存はなく、WhisperKit・TCA・Google Tasks・アプリのモデルや翻訳を参照しない。

## クライアント

```swift
import LocalLLM

let client = LocalLLMClient()
let model = "apple.foundation-models"

// テキスト生成
let text = try await client.generate(model: model, prompt: "短い挨拶を作って")

// タスク操作の構造化提案
let plan = try await client.generateTaskPlan(model: model, prompt: prompt)
```

生成時の引数はモデル名とプロンプトのみ。`generate`はString、`generateTaskPlan`はSDKに依存しないCodable / Sendableの`TaskPlan`を返す。後者のプロンプトには基準日、タイムゾーン、利用可能なリストとタスクのJSON、ユーザー指示を含める。アプリは戻り値の対象ID・日時などを現在のデータと照合し、ユーザーの確定後に保存する。パッケージはタスクデータを書き換えない。

`availability(model:locale:)`で表示言語に応じた可用性を確認できる。推論開始時にもパッケージ内でモデルの利用可否を再確認する。`supportedModels`は実装済みのモデル名だけを返す。

## モデルの選択と追加

現在対応するモデルは`apple.foundation-models`（`LocalLLMModel.appleFoundationModels`）のみ。Apple Intelligenceを利用可能な端末で、モデルの準備が完了している必要がある。未知のモデル名は`unsupportedModel`になり、他のモデルへの暗黙の切り替えやダウンロードは行わない。

`LocalLLMClient`がモデル名をキーに内部の`LocalLLMBackend`を選択する。別のモデルを追加する場合は次の手順を使う。

1. パッケージ内に`LocalLLMBackend`準拠の実装を追加する。SDK、モデル読み込み、実行設定、セッションの寿命はその実装で管理する。
2. テキスト生成と構造化タスク提案を実装し、生成結果を共通の`TaskPlan`へ変換する。自由生成を使う場合もJSONのデコード等はバックエンド側で行う。
3. 本番用クライアントのモデル辞書へ固有のモデル名で登録する。
4. バックエンドのテストと、実モデルを用いた明示実行の結合テストを追加する。

アプリ側は呼び出しに渡すモデル名を変更する。推論SDKやバックエンド別のswitchを追加する必要はない。

## 非同期処理と失敗

クライアントは不変のSendableクラスで再利用できる。Appleバックエンドはリクエストごとに独立した`LanguageModelSession`を作るため、会話履歴や途中結果を別の呼び出しと共有しない。`Task.detached`を作らず、呼び出し元のキャンセルを引き継ぐ。推論がキャンセルに即時応答しなくても、終了後のチェックで遅れた結果を破棄する。モデルの実行を即時に停止できるかはSDKに依存する。

`LocalLLMError`は未対応モデル、モデル利用不可、空プロンプト、生成失敗を区別する。`CancellationError`は変換せず返す。エラーメッセージの翻訳と画面への表示はアプリが担当する。

Appleバックエンドはタスク提案にガイド付き生成を使う。Foundation Modelsの型と`@Generable`はパッケージの内部だけで使用する。[Appleのガイド付き生成の説明](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)

## 検証

```sh
swift test --package-path Packages/LocalLLM
LOCAL_LLM_INTEGRATION=1 swift test --package-path Packages/LocalLLM
```

1行目はSDKを呼ばないモデル振り分け・可用性・型付き結果・エラー・並列実行・キャンセルのテスト。2行目は端末のモデルが利用可能なら、短い合成プロンプトによる実生成も確認する。通常CIは実モデルを必要としない。整形・lint・単体テストはルートの品質ゲートに組み込む。
