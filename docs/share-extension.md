# Share Extension

macOSとiOSの共有メニューから、ページやテキストをgreminderのToDoとして保存する。

## 実画面で確認したリマインダーの挙動

2026-09-18〜19、Computer UseでDiaのmacOS共有メニュー、およびiPhone 17 Pro Max / iOS 26.2のSafariからリマインダーを開いて確認した。

- iOS: リスト選択、ページタイトル・URLの自動入力、追加行、キャンセルとチェックマークによる確定。行を編集すると情報ボタンが現れ、詳細に日付・時刻・優先順位・場所が表示される。
- macOS: タイトルとリンクを含む行、追加行、下部のリスト選択、キャンセルと「追加」。詳細にはタイトル・メモ・URL・日付・時刻・緊急・タグ・フラグ・優先順位・場所・メッセージ送信時・画像の項目がある。
- 比較用の入力は確定せず閉じた。Appleリマインダーへの保存・同期の完了はこの調査では確認していない。

greminderでは既存のタスクモデルに対応するタイトル・メモ・URL・リスト・日付・通知時刻・複数行追加を実装する。優先順位、場所、タグ、緊急アラーム、画像添付、メッセージ連動は既存モデルにないため対象外。

## 利用方法

1. greminderを一度開き、Googleアカウントに接続してリストを読み込む。
2. SafariやDiaなどの共有メニューでgreminderを選ぶ。初回は「その他」や共有機能拡張の設定から有効にする。
3. タイトルを編集し、保存先を選ぶ。情報ボタンでメモ・URL・日付・通知時刻を編集できる。「新規ToDo」で複数件をまとめて追加できる。
4. 「追加」で端末の共有コンテナに保存され、共有画面が閉じる。キャンセルは保存しない。
5. greminderを開くと、既存の保存キューからGoogle Tasksへ同期する。本体が前面にある場合は数秒以内に取り込む。

共有画面にも本体起動時に同期する旨を表示する。本体が起動していない状態でのGoogleへの即時送信や通知予約は行わない。通知時刻を使うには本体で通知を有効にし、指定時刻より前に本体を開く。URLはGoogle Tasksのメモへ空行区切りで保存する。

共有元が提供したタイトルを使用する。Safariでは前処理JavaScriptからタイトル・URL・選択テキストを受け取る。タイトルが提供されない場合はテキストの先頭行またはURLのホスト名を使う。共有先からページを再取得しない。対応入力はHTTP(S) URLとテキストで、画像・ファイル添付には対応しない。

## 構成と署名

`project.yml`を正本とし、`xcodegen generate`でプロジェクトを再生成する。

- `Greminder-Share-iOS` / `Greminder-Share-macOS`: `com.apple.share-services`の拡張。本体アプリに埋め込む。
- `GreminderShare`: FoundationとSwiftUIで利用する軽量な共有モデル・ストレージ・入力読込。Google Sign-In、TCA、音声・AIモデルは拡張にリンクしない。
- `ShareInboxClient` / `AppFeature+Sharing`: 本体のアカウント・リストを公開し、同じアカウントの共有ToDoを既存の保存キューへ取り込む。

本体と対応する拡張を同じDevelopment Teamで署名し、両方のApp IDにApp Groupsを有効にする。共有グループは`group.com.example.greminder`。実機配布時に識別子を変更する場合は`project.yml`の4ターゲットと`ShareInbox.groupIdentifier`を合わせて変更し、対応するプロビジョニングプロファイルを用意する。署名なしのビルド成功だけでは実機のApp Groups権限を検証できない。

Team IDはGit管理外の`Config/Local.xcconfig`に`DEVELOPMENT_TEAM = <Team ID>`として保存できる。4ターゲットが共通で読み込むため、`xcodegen generate`後も署名チームを維持する。通常はAutomatically manage signingを有効にし、macOSもSign to Run LocallyではなくApple Development証明書を使用する。

## 保存の保証

`NSFileCoordinator`でプロセス間の読み書きを直列化し、JSONファイルをatomicに置き換える。複数件の確定は一括保存する。アカウントとリストを確定時にも検証し、別アカウントや削除済みリストへの自動的な振り替えをしない。壊れたデータや未対応バージョンを空データで上書きしない。

各ToDoのUUIDにより共有画面の二重確定と繰り返し読込を重複排除する。送信前に`sending`、成功後にGoogleのIDと`saved`を記録する。送信中に終了したものは自動再挿入せず、本体に確認と再試行の案内を出す。Google Tasksは挿入の冪等キーを提供しないため、ネットワーク送信とローカル成功記録の間で終了したケースは利用者による確認が必要。

成功記録は通知設定の保存が完了するまで保持する。通知の保存に失敗した場合も再起動後にGoogleのIDから復元し、再挿入しない。

## 動作確認

- iPhone 17 Pro Max / iOS 26.2のSafari共有メニューにgreminderが表示されることを確認。ページ名「Apple（日本）」とURLを受け取り、タイトル編集、予定日指定、保存先を「プライベート」へ変更、2行の一括追加を操作した。
- サンプルAPIへ「Share Extension Test - Apple」「Share Extension Test - Second」を保存。本体のリストでURL・予定日とともに表示され、終了・再起動後にも2件が保持されることを確認した。実Googleアカウントへのテスト書込みは行っていない。
- 初回確認ではiOS Simulatorの署名付きビルドとmacOSの署名なしビルドが成功。macOSの署名付きビルドはTeam未設定で停止した。2026-09-19にXcodeで本体・共有拡張のTeamを既存のPersonal Teamに統一し、macOS / My Macの開発署名付きビルドが警告・エラーなしで成功した。macOSの共有拡張の起動・保存と実機iOSでの動作は未検証。
- 同日、元の`Greminder.xcodeproj`をXcodeで操作し、iOS / Any iOS Device (arm64)の開発署名付きビルドも成功した。iOSには`All interface orientations must be supported unless the app requires full screen.`の画面方向に関する警告が1件残るが、署名エラーは解消している。
- 元のXcodeプロジェクトはXcodeのファイル協調待ちでビルド開始が停止したため、同じ`project.yml`から`Build/ShareVerification`へ生成した検証用プロジェクトを使用。ソース参照先は同一で、検証用コピーのみプロジェクト位置に合わせてパッケージ・Info.plist・entitlementsの相対パスを調整した。
- `swift test`: XCTest 94件（1件スキップ）とSwift Testing 40件、失敗なし。追加した共有関連13件では入力、永続化、重複排除、アカウント・リスト変更、保存失敗、通知設定の復元を検証した。
- `bash scripts/quality.sh check`: フォーマット・lint・日本語/英語のキー整合性が成功。`git diff --check`も成功。

参考: [Appleの共有コンテナと拡張の説明](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)、[App ExtensionのInfo.plistキー](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html)。
