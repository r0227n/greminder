# コードレビュー（2026-09-20）

アプリ本体、SwiftUI画面、通知・音声・Google接続、共有拡張、内部LocalLLMパッケージとテストを、状態の所有権、非同期処理、保存順序、UIの操作性から確認した。重大な指摘は下表のとおり修正した。ただし、SOLID原則への完全準拠や、未同期データの終了時耐久性まで保証する結果ではない。

**構造上の評価**

| 観点 | 評価と根拠 |
|---|---|
| SSOT | `AppFeature.State`が画面のタスク、選択、編集、保存キューを所有し、件数・一覧・通知表示はそこから導く。共有拡張向け`shareContext`もStateの計算プロパティとし、独立した可変状態を増やさない。プロセス間の公開ファイルは、この状態から作る派生データである。 |
| 編集ドラフト | `TaskEditor.task`と`TaskSnapshot.tasks`の共存は、未検証の入力と確定済みの楽観更新を分けるために必要。値の重複だけをSSOT違反とは扱わない。検証、確定、取消、保存結果のID反映をReducerが管理する。 |
| 単一責任・依存性逆転 | 外部処理はTCAの依存クライアントへ分離され、テストから差し替えられる。音声・通知・音声設定は子Reducerを持つ。今回、保存キューを`AppFeature+Persistence`へ分離したが、同じStateへの依存は残るため、ファイル分割だけで責務分離が完了したとは評価しない。 |
| UIコンポーネント | `TaskRow`は表示値と操作コールバック、`TaskNotificationEditor`はBindingを受け取り、ルートStoreや保存サービスを所有しない。フォーカスとピッカー展開はViewに置き、業務上の確定処理はReducerに置く。 |
| 開放閉鎖・置換可能性 | Google接続、通知、音声、AIは依存境界を通して差し替えられる。一方、将来のAPIやモデルに対する完全な拡張性・置換可能性は、現在の実装とテストだけでは証明できない。不要な継承階層や抽象化は追加していない。 |

**修正した指摘**

優先度はP1をデータ・認証状態・保存処理に影響する高優先、P2を機能不整合・操作性・保守性の問題として扱う。回帰テストは最終版で全件成功した（実モデルを必要とする任意テストはスキップ）。

| 優先度 | 原因と影響 | 修正 | 回帰の証拠 |
|---|---|---|---|
| P1 | Xcodeプロジェクトに同じIDのResourcesグループが二重定義され、共有拡張のJavaScriptがルート直下の存在しないパスとして解決され、ネイティブビルドに失敗した。生成元にも署名チーム設定がなく、再生成で設定が失われた。 | [project.yml](../project.yml)を正本として再生成し、既存の署名チームを共通設定へ移行。最小XcodeGenバージョンを明示し、無効なfileType指定を除去。 | 2回の再生成で同一結果。iOSホストテストのコンパイル・macOSビルド成功。Icon Composerのactool処理も確認。 |
| P1 | 共有タスクの初回送信中に削除して送信が失敗すると、永続受信箱の送信記録が残り、次の取り込みで削除済みタスクが復活した。 | [AppFeature+Persistence](../Greminder/AppFeature+Persistence.swift)で削除意思を先に永続化。通信失敗時は結果不明の記録を保持して手動確認へ進み、ID既知なら削除を再開する。v2形式で旧版による削除意思の消失も防ぐ。 | [SharedCancellationRegressionTests](../Tests/SharedCancellationRegressionTests.swift)と[SharedDeletionPersistenceTests](../Tests/SharedDeletionPersistenceTests.swift)：サーバー保存後のタイムアウト、再起動、ディスク失敗、遅延成功、子孫削除、手動確認と旧形式移行。成功。 |
| P1 | 通知編集を複数Actionで渡す途中で古い同期が成功すると、通知時刻・ON/OFFの保存より先に共有受信箱の記録を削除できた。 | [NotificationFeature](../Greminder/NotificationFeature.swift)でスナップショット・編集・同期開始判断を一括処理。親は子へ適用済みになるまで編集記録を保持する。 | [ReviewRegressionTests](../Tests/ReviewRegressionTests.swift)と[NotificationAndSpeechStateTests](../Tests/NotificationAndSpeechStateTests.swift)：古い同期結果と共有受領記録の保持。成功。 |
| P1 | Googleで削除成功後にローカル受信箱の更新が失敗すると、再試行時のHTTP 404が保存キューを止め続けた。 | [GoogleTasksService](../Greminder/Services/GoogleTasksService.swift)は既知のSDK HTTPエラードメインの404だけを削除完了と扱い、認証・権限・競合エラーは保持する。 | [GoogleTasksDeletionTests](../Tests/GoogleTasksDeletionTests.swift)：再削除、2種のSDKドメイン、他のHTTPコード・同番号の非HTTPエラー。成功。 |
| P1 | 認証復元・初回取得・API切替の`await`中に新しい操作が完了すると、古い応答がログアウトや新しい接続先を上書きできた。MainActorだけでは非同期の再入を防げない。 | [TasksEnvironment](../Greminder/Services/TaskClient.swift)に操作IDとキャンセル検証を導入。最新の有効な操作だけが接続・プロフィール・保存設定を公開する。 | [TasksEnvironmentConcurrencyTests](../Tests/TasksEnvironmentConcurrencyTests.swift)：復元遅延、初回取得遅延、切替キャンセル、古いログイン結果。成功。 |
| P1 | 削除済み行への詳細・完了操作が先行エディタを確定した後、対象不在で早期returnし、追加済み保存キューの処理を開始しなかった。 | [AppFeature](../Greminder/AppFeature.swift)は対象が消えていても、確定済み入力の`processQueue`を開始する。 | [ReviewRegressionTests](../Tests/ReviewRegressionTests.swift)の`testStaleRowActionsStillSaveThePreviousValidEditor`。成功。 |
| P1 | 通知設定の保存がタスク取得完了を必須としていたため、未取得・取得失敗中に設定変更が永続化されず、通知OFFもOS予約へ届かなかった。 | [NotificationFeature](../Greminder/NotificationFeature.swift)と[NotificationClient](../Greminder/Services/NotificationClient.swift)で設定保存と予約更新を分離。未取得のスナップショットで予約を消さず、明示OFFは取消。既存の直列処理を維持。 | [NotificationAndSpeechStateTests](../Tests/NotificationAndSpeechStateTests.swift)：取得前保存、設定保存と初回タスク取得の順序。成功。 |
| P2 | 音声設定を読み込む前、または読込失敗後に一項目を変更すると、もう一項目を初期値で上書きできた。 | [SpeechSettingsFeature](../Greminder/SpeechSettingsFeature.swift)は未読込なら保存値を読み、成功した値に変更を適用。読込失敗時は保存しない。 | [NotificationAndSpeechStateTests](../Tests/NotificationAndSpeechStateTests.swift)：言語・モデルの保持、破損設定の保護と復旧。成功。 |
| P2 | 添付に無関係なpropertyListや非Web URLがあると、同じ添付の有効なテキスト表現まで読み飛ばした。 | [ShareItemLoader](../ShareSupport/ShareItemLoader.swift)は優先表現が利用不能なら次の表現を読む。 | [ShareItemFallbackTests](../Tests/ShareItemFallbackTests.swift)：propertyListと非Web URLからのテキスト復元。成功。 |
| P2 | 共有ドラフトの予定日が絶対日時だけで保存され、別タイムゾーンで本体が取り込むと暦日が変わり得た。日付検証もアプリ側に閉じていた。 | [CalendarDay](../ShareSupport/CalendarDay.swift)をアプリ・共有拡張の共通値型にし、`TaskDay`は別名に変更。[ShareDraft](../ShareSupport/ShareDraft.swift)の正本を暦日に統一し、旧形式の読み込みと互換キーを保持。 | [SharedCalendarDayTests](../Tests/SharedCalendarDayTests.swift)：複数タイムゾーン、旧形式移行、不正暦日、DatePicker更新・削除。成功。 |
| P2 | 完了一覧の所属判定が、完了した親の未完了子タスクまで含め、表示と件数の意味が崩れていた。 | [TaskSnapshot](../Greminder/Models/TaskModels.swift)の共通所属判定で、完了一覧は実際に完了したタスクだけを返す。 | [ReviewRegressionTests](../Tests/ReviewRegressionTests.swift)の`testCompletedListExcludesUnfinishedChildrenFromRowsAndCount`。成功。 |
| P2 | 選択リスト・表示言語・通知設定の変更後、共有拡張へ公開する設定が次のポーリングまで古いままだった。 | [AppFeature+Sharing](../Greminder/AppFeature+Sharing.swift)で`shareContext`を一か所から導き、該当する状態変更時に即時公開する。 | [ReviewRegressionTests](../Tests/ReviewRegressionTests.swift)の`testShareContextTracksSelectionLanguageAndLoadedNotificationPreferencesImmediately`。成功。 |
| P2 | macOS詳細とインライン編集は個別通知OFFでも日時を表示し、通知を有効に戻す操作がなかった。 | [TaskNotificationEditor](../Greminder/Views/TaskNotificationEditor.swift)へ共通化。`editorNotificationEnabled`を表示の正本にし、ON/OFF操作と有効時の日時編集を同じスケジュールActionへ接続。 | 編集ファイルの構文解析・整形・lint成功。既存`AppConsistencyTests`が無効通知の日時保持を検証。Simulatorで共通エディタのOFF時非表示・ON時9:00復元を確認。macOSでの実操作は未確認。 |
| P2 | タイトル編集がタップジェスチャーに依存し、完了・詳細などの操作領域もiOSで小さかった。行表示が巨大な一覧Viewに埋め込まれていた。 | [TaskRow](../Greminder/Views/TaskRow.swift)を抽出し、タイトルを標準Button化。iOSの行操作を44ptにし、共通完了ボタンを両OSのサブタスクでも使用。行の文字には意味付きフォントを使用。 | 編集ファイルの構文解析・整形・lint成功。Simulatorでタイトルから編集・詳細表示・スワイプ削除・件数更新を確認。VoiceOver、キーボード、全Dynamic Typeの実操作は未検証。操作領域は[Appleの設計ガイド](https://developer.apple.com/design/tips/)を参照。 |
| P2 | 新規リストの色・アイコンが6列固定のため、狭い幅では44ptのボタンと間隔を収容できなかった。 | [NewListSheet](../Greminder/Views/NewListSheet.swift)を最小44ptの適応グリッドへ変更。 | 編集ファイルの構文解析・整形・lint成功。狭幅の実画面確認は未検証。 |

追補レビューで見つかった完了済みタスクの通知編集喪失も修正した。`NotificationFeature`は完了済みでも編集を受け取り、`NotificationPlanner`は予定日がある限り記録を保持する。完了中の通知予約は行わない。[CompletedTaskNotificationTests](../Tests/CompletedTaskNotificationTests.swift)で詳細編集からの親子Reducer連携、ON/OFFと時刻、再同期・再起動・未完了化、ID移行を検証した。

**残る課題と制約**

- 通常入力の未同期保存キューはメモリ上にある。保存成功前のアプリ終了では失われ得る。共有拡張の永続キューとは保証範囲が異なり、[ShareInboxClient](../Greminder/Services/ShareInboxClient.swift)は共有由来のIDだけを永続化対象にする。通常入力の永続outboxは今回追加していない。高優先の継続課題として、ローカルID・リモートID・操作順序・ETag・挿入結果不明時の重複処理まで含めた設計が必要である。
- `AppFeature`には編集、ナビゲーション、接続、子機能の調整が残る。保存処理の抽出で見通しは改善したが、独立した機能境界になったわけではない。今後の分割でも、同一タスクの保存順序と編集確定の責任を分散させないことが必要である。
- 旧共有ドラフトには作成時のタイムゾーンが保存されていない。新形式は暦日を維持できるが、すでに別タイムゾーンへ移った旧形式から作成時の意図を完全には復元できない。
- 実Google OAuth、実通知配信、実モデル推論、全画面幅・全Dynamic Typeサイズは未検証。署名なしSimulatorでは共有コンテナのアクセスエラーを確認したため、共有拡張とのプロセス間連携はユニットテストとコンパイルまでの確認である。

**最終検証**

| 検証 | 結果 |
|---|---|
| UI変更6ファイルのSwiftFormat・SwiftLint strict・Swift構文解析 | 成功、lint違反0 |
| プロジェクト全体の整形・lint・翻訳整合性 | 成功。81 Swiftファイル、lint違反0。アプリ331キー・共有24キーの日英整合性成功 |
| アプリのカバレッジ付きテスト | 178件中177件成功、任意の実Whisperテスト1件スキップ、失敗0（XCTest 118件＋Swift Testing 60件） |
| LocalLLMパッケージのカバレッジ付きテスト | 9件中8件成功、任意の実Appleモデルテスト1件スキップ、失敗0 |
| macOS署名なしビルド | 成功。アプリ・共有拡張を含む |
| iOS Simulatorビルド・ホストテストのコンパイル | 成功。アプリ・共有拡張・ホストテストを含む |
| 実画面での回帰確認 | iPhone 17 Pro Max / iOS 26.2のサンプルで編集・通知ON/OFF・詳細・スワイプ削除を確認。[記録と画像](diagnostics/review-2026-09-20/README.md) |

追補修正では全アプリテスト、整形・lint・翻訳整合性、両OSのビルドを再実行した。新しい共有削除の確認UIはコンパイルとReducerテストまでの検証で、実Google連携・実画面操作は未検証。LocalLLMは変更しておらず上表は前回の実行結果である。

検証コマンドと環境要件は[QUALITY.md](QUALITY.md)を参照。

XcodeGen設定の記法は[2.44.1の公式Project Spec](https://github.com/yonaskolb/XcodeGen/blob/2.44.1/Docs/ProjectSpec.md)を参照。生成ファイルへ直接追記して修復する運用は避け、project.ymlから再現できる状態にした。
