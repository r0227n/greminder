# Large v3 TurboのSimulatorクラッシュ

調査日: 2026-09-14（JST）

## 原因と修正

iOS 26.2 SimulatorのCore ML / BNNSが、Large v3 Turboの音声エンコーダー用作業ファイルを作る際にMacの空き容量を使い切っていた。コンパイルは`No space left on device`を記録するが、WhisperKitのモデル準備は成功として戻り、その後の推論が`SIGABRT`または`SIGSEGV`で落ちる。アプリのSwiftエラー処理で捕捉できる失敗ではなかった。

約626 MBは配布モデルのサイズであり、CPU実行のコンパイルキャッシュのサイズではない。約3.6 GiBの空きでも失敗を再現した。空きを確保した後は同じモデル、同じiOSアプリホストで日本語の文字起こしが成功した。検証中のアプリ専用Core MLキャッシュは約5.8 GiBまで増加した（複数回実行したキャッシュの合計であり、単一モデルの最大必要量ではない）。

`SpeechStorage`を追加し、モデル準備開始、ダウンロード後のCore ML読み込み前、録音前、文字起こし前に保存先ボリュームの空き容量を検証する。準備済みパイプラインの再利用でも確認する。不足時はSDKを呼ばず`AppFailure`を返し、必要な空き容量・現在値・再試行方法を音声画面に表示する。容量取得不能もエラーとする。

| モデル | Simulatorの下限 | iOS実機・ネイティブMacの下限 |
|---|---:|---:|
| Tiny | 100 MB | 100 MB |
| Base | 250 MB | 250 MB |
| Small | 500 MB | 500 MB |
| Large v3 Turbo | 8 GB | 2 GB |

下限は安全余裕を設けるためのアプリの実行条件であり、メーカーの保証値・実測した最低必要量ではない。準備によって空き容量も減るため、初回はモデル本体と生成されるキャッシュの分も余裕を持たせる。検証後に別のプロセスがディスクを消費する競合や、実機のメモリ不足はこのチェックの対象外。

## 再現条件と切り分け

- Xcode 26.3 / Swift 6.2.4、iPhone 17 Pro Max / iOS 26.2 Simulator（arm64）。
- WhisperKit 1.1.0、`openai_whisper-large-v3-v20240930_626MB`。
- 合成音声「明日、牛乳を買う。」をiOSのテストバンドルから入力。マイクの入力経路は使わない。
- [WhisperKitの`ModelComputeOptions`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/Sources/WhisperKit/Core/Models.swift)はSimulatorでCPU実行を選択する。アプリはこの標準設定を維持する。
- MelSpectrogramだけの実行は成功。AudioEncoderのロードでBNNSコンパイルが容量不足となり、encodeFeatures実行で停止した。
- GPU指定も調査したが、このSimulatorは`Espresso compiled without MPSGraph engine`を返してCPUへ戻るため解決しなかった。GPUへの強制切り替えは実装に残していない。
- 空きを確保すると、同じ段階別テストが成功。続く実アプリの`WhisperSpeechEngine.prepare` → `transcribeFile`も、日本語固定・自動言語判定の両方で「明日、牛乳を買う。」を返した。

## 検証証跡

XcodeBuildMCPのローカル保存先: `~/Library/Developer/XcodeBuildMCP/workspaces/greminder-63ae9b869d55/`。ログは`logs`、XCTest結果は`result-bundles`に保存される。

| 条件 | ログ名 | 結果 |
|---|---|---|
| 空き約3.6 GiB、修正前 | `test_sim_2026-09-13T15-11-37-431Z_pid71270_86c7b258.log` | ENOSPC、推論でSIGABRT |
| Mel / Encoder個別実行、容量不足 | `test_sim_2026-09-13T15-18-43-415Z_pid71270_ecbde740.log` | Mel成功、Encoderで停止 |
| 空き確保後、同じ個別実行 | `test_sim_2026-09-13T15-22-04-458Z_pid71270_364ded08.log` | 1件成功 |
| 容量チェック追加後、Turbo日本語・自動判定 | `test_sim_2026-09-13T15-23-43-419Z_pid71270_e851ec4a.log` | 1件成功、両方で期待文を認識 |
| 最終コード、Small準備からの切り替え、Turbo認識、容量の回帰テスト | `test_sim_2026-09-13T15-33-34-267Z_pid71270_ab0ff99d.log` | 4件成功。Smallの独立診断1件はスキップ |

代表的な実行ログ:

```text
00:19:14 Speech stages: Mel succeeded; load Encoder
         BNNS Graph Compile: failed to preallocate file ... No space left on device
00:19:24 Speech stages: run Encoder
         malloc: Incorrect checksum for freed object

00:22:09 Speech stages: Mel succeeded; load Encoder
00:22:18 Speech stages: run Encoder
00:22:23 Speech stages: Encoder succeeded

00:24:30 SpeechSimulatorTests: result 明日、牛乳を買う。
00:24:36 SpeechSimulatorTests: result 明日、牛乳を買う。
```

標準テストは容量不足・容量不明・境界値、SDK呼び出し前の停止、TCAのエラー表示と空き確保後の再試行を検証する。実機でのマイク録音、全言語や長い音声での精度・性能はこの検証に含めていない。

標準SwiftPMテストは28件成功・実モデル1件スキップ（`/tmp/greminder-swift-test-storage.log`）。SwiftFormat / SwiftLintも成功（`/tmp/greminder-quality-storage.log`）。GitHub ActionsのiOSジョブにホストテストのコンパイルを追加したが、リモートCIは未実行。

通常起動したSimulatorでも、日本語 / Large v3 Turboのモデル準備から「録音を開始」へ進むことを確認。マイクは開始せず、この画面で待機させた。

![通常起動でLarge v3 Turboの準備完了](large-v3-turbo-ready.jpg)

## 追加で検出したSmallの認識不一致

比較中、SmallはSimulatorでクラッシュせずに処理を完了するが、同じ合成音声から「アッ…」等の誤った文を返した。Core MLキャッシュを再生成しても再現した。ネイティブMacで同じ音声・モデルを使うテストは日本語固定・自動判定とも成功し、Simulatorと新規取得したMacモデルの3つのweight.binのSHA-256も一致した。

このSmallの認識不一致の原因と修正は未完了。今回のTurboの容量不足クラッシュが解消したことと、Smallの精度が正常であることを混同しない。`iOSTests/SpeechSimulatorTests.swift`に失敗する精度アサーションを独立した任意診断として残している。再現手順は[QUALITY.md](../QUALITY.md)。

比較ログ: `test_sim_2026-09-13T15-26-38-620Z_pid71270_c06c6575.log`、キャッシュ再生成後: `test_sim_2026-09-13T15-28-52-495Z_pid71270_58de1ae1.log`。両方でTurboは期待文を認識している。MacのSmall成功ログ: `/tmp/greminder-small-native.log`。
