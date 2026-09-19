# UI回帰確認（2026-09-20）

XcodeBuildMCPでビルド済みiOSアプリを起動し、iPhone 17 Pro Max / iOS 26.2 Simulatorで以下を確認した。

起動引数は`--design-preview -greminder.api.usesMockAPI YES`。保存済みAPI設定がプレビューの既定値より優先されるため、NSArgumentDomainで今回の起動だけモックAPIを指定した。操作前に`sample-0`〜`sample-3`のタスクを確認し、実Googleアカウントは使用していない。

| 操作 | 結果 |
|---|---|
| 「資料の構成をまとめる」のタイトルをタップ | 同じ行に`task-title-input`が現れ、インライン編集へ遷移。 |
| インラインの「端末の通知」をOFF→ON | OFFで日時ピッカーが消え、ONで元の9:00が再表示。 |
| インラインの詳細ボタンをタップ | 詳細シートに同じタイトル・予定日・9:00が表示。完了ボタンで一覧へ戻る。 |
| 「デザイン案を確認する」を左スワイプ | `task-swipe-delete-sample-1`の削除ボタンを表示。 |
| スワイプで現れた削除ボタンをタップ | 対象行が消え、今日の件数が4→3に更新。 |

検証後に同じプレビュー引数で再起動し、メモリ内サンプルを元に戻した。テキスト変更、録音、実通知配信、実アカウントへの保存は行っていない。

この署名なしSimulatorビルドでは共有コンテナを開けず、共有データのエラーバナーが表示された。共有拡張の連携確認は、このスモークテストの成功範囲に含めない。VoiceOverの実操作、ハードウェアキーボード、全Dynamic Typeサイズ、狭い画面でのグリッドは未確認。

- [通知OFFのインライン編集](inline-notification-disabled.jpg)
- [詳細シート](task-detail.jpg)
- [スワイプ削除ボタン](swipe-delete.jpg)
- [削除後の一覧](after-delete.jpg)
