# Issue #11 ローカル検証記録

基点: develop `d52e1c8ac08773c39f74a991431eaabc5f6b2355`（#10 PR #27統合）。ブランチ: `feature/issue-11-app-zone-history`。対象: [Issue #11](https://github.com/a2c-j1/AppAlign/issues/11)。

検証日: 2026-10-17（Asia/Tokyo）。状態は **LOCAL_READY（作業セッション内のローカル受け入れ）**。公開push・PR作成・マージ・Issue完了処理は未実施。最終HEADはignoredの `build/issue-11-evidence/manifest.json` に記録する。GUI・実機の受け入れは統括側で別途行う。

機能修正と責務分割を完了し、固定した97入力ファイルに対して品質チェックと公式全suiteが成功した。親は文書、workerはソース・テスト・projectを担当し、同一ファイルの同時編集を避けた。残る確認はGUI・実機と、公開に向けた統括レビューである。

## 動作と境界

- 成功した明示配置をbundle ID・永続ディスプレイUUID・共通Space scope・LayoutID・正規化ZoneIDsで記録する。PID、AX参照、ウィンドウタイトル、文書URLは永続化しない。
- ランタイムassignmentと永続履歴を分離する。同じキーでは最初の配置成功ウィンドウが更新権を持つ。同一PIDの複数ウィンドウ、同一bundle IDの複数PIDでも後続ウィンドウが上書きしない。所有ウィンドウの破棄・スコープ移動で更新権を引き継ぎ、引き継ぎ自体は保存しない。
- 手動配置・キーボード配置・拡張・ドラッグ配置は、実測フレームと現在のticketを検証した成功境界で履歴を更新する。失敗・中断・手動Restore・自動復元は履歴を書き換えない。手動Restoreの元矩形を維持する。
- 監視と自動復元の初期値は両方オフ。既存プロセスはsubscribe後のbaselineを基準にし、監視開始後の新規プロセス初期ウィンドウとbaseline後の新規ウィンドウを候補とする。
- 履歴assignmentは64 unique token、monitor seenは64 unique token、和集合は最大128。runtime全体128 recordsと既存所有権を維持する。同じtokenのlease交換では一時的に2 leaseまで保持する。
- process observerは64、callback inboxは128でcoalesceしdrainは一つ。overflowは当該epochの自動処理を失効し、旧seen leaseを解放してfresh baselineを作る。停止後の古い処理は再開しない。
- 自動復元episodeは未完了処理を含め最大8。準備待ちは開始から0/100/300/700/1500ms、総期限5秒。自動AX呼び出しは残予算と200msの小さい方、配置のsetter再試行は0。手動・通常キーボードの500ms設定と分ける。
- 復元先はウィンドウの正の重なり、グローバル座標のカーソル、主画面、安定したUUID順。接続中画面の現在適用LayoutIDと全ZoneIDsが有効な履歴だけ採用する。未接続画面の履歴は保持する。
- 履歴は既存の保存FIFO、VersionedStore、AtomicFileAccess、バックアップを使う。同一パスのprocess内claimとPOSIX lockで複数writerを拒否する。開始時から履歴が利用不能な場合は基本レイアウト保存を妨げず、受理済み更新・pruneの失敗はRetry/flushまで保持する。
- 権限撤回は有効中の単一1秒timerで検知する。自動処理、監視、当該seen leaseを停止し、権限の再許可後は明示Retryでbaselineを取り直す。quitはauto/monitor/dragのdrain後に保存flushへ進む。
- Space scopeはcommonのみ。公開Space切替はpending処理を取り消す。Space固有の解決・強制移動は#12以降。

## 自動検証

最終ログ・結果束とハッシュを以下に固定した。中間の失敗ログは成功証拠にしない。

| 項目 | 結果・証拠 |
|---|---|
| 基点の全テスト | 220成功、失敗0、skip0、expected failure0。baseline-escalated-scripts-test.log / AppAlignTests-20261016T001338Z-92112.xcresult |
| 基点結果の親独立確認 | parent-baseline-xcresult-summary.json |
| 最終macOS build / XCTest / bundle smoke | 公式scripts/test.sh成功。264成功、失敗0、skip0、expected failure0 |
| 最終結果束・実行ログ | AppAlignTests-20261017T122007Z-87266.xcresult / scripts-test-final.log |
| 親の独立結果確認 | parent-final-xcresult-summary.json。ログ264件とソース264メソッドの実行一致をparent-final-executed-tests.jsonへ記録 |
| SwiftFormat / SwiftLint / Semgrep | 親のlint modeで0/86要整形、strict/no-cache SwiftLint 0件。Semgrepは4 rules・未追跡を含む全50 source・0 findings。parent-final-format.log / parent-final-lint.json / final-semgrep-all-sources.log。設定・閾値・ルール・検証scriptの変更なし |
| project / patch | plutilとgit diff --check成功。新規Swift 19件の登録漏れ0、参照先欠落0、新規production 8件も全件test targetに含む。parent-project-registration.json |
| 既存テスト保持 | 既存220 methodを全件保持、assertion減少0、新skip0。移動8件の対応表はparent-baseline-preservation.json。旧manual assertion目的も親レビューで保持を確認 |
| ハッシュ | source-freeze.jsonと親post-testの97入力・実行ファイルSHA一致。最終HEAD、入力、アプリ、ログ、xcresultをmanifest.jsonで結び付ける |
| 実行環境 | arm64、macOS 27.0.1（26A434）、Xcode 26.5（17F42）。parent-environment.json |

証拠はignoredの `build/issue-11-evidence/` に保存する。初回のsandbox内baselineはtestmanagerd error159で失敗した。上記220成功は必要権限で再実行した別結果束であり、失敗ログを成功扱いしない。

## 要件と主要回帰証拠

ファイル分割後の登録と実行ログを親が照合した。以下の対象を最終全suiteに含む。

| 要件・境界 | 実装・検証対象 |
|---|---|
| 安定キー、正規化、疎・結合ZoneID、無効履歴 | AppZoneHistoryPersistence / AppZoneHistoryPersistenceTestsの履歴round-trip・sparse merged grid・stale layoutテスト |
| 保存時のexact layout照合、削除とprune | AppHistoryLayoutIntegration / AppZoneHistoryPersistenceTestsのsuperseded layout・prune失敗Retry |
| 開始時unavailableと受理後I/O失敗の分離 | AppZoneHistoryPersistenceTestsのwriter unavailable・backup failure・accepted prune failure |
| invalid履歴も含むrevision最大値・overflow | AppZoneHistoryPersistenceTests.testInvalidHistoryKeepsRawRevisionSeedAndMaxRevisionDoesNotBlockBaseFlush。Controller経路でinvalid rev100→101、UInt64.maxでは新規更新停止とbase flush成功 |
| owner、scope移動、64 unique token | AppHistoryCoordinatorTests / RuntimeWindowOwnershipTests |
| 作成監視オフ時もdestroy通知でowner移譲 | NewWindowMonitorTests.testRuntimeDestroyObserverTransfersOwnerWithoutPersistingUntilNextPlacement |
| 遅延destroy callbackとlifecycle revision | NewWindowMonitorTests.testStoppedHistoryDestroyEpochRejectsLaterRuntimeNotifications |
| 手動async経路とreadback後の新Capture | KeyboardSnapControllerTestsのmanual invalidation・stale readback、runtime barrier |
| 手動history retain中のlayout/capture変更 | KeyboardSnapControllerTests.testManualHistoryLeaseWaitRejectsQuickLayoutAndSameTokenRecapture。retain入口を確認してlayout切替・同token再Captureを注入、setter0とRestore維持 |
| keyboard画面横断はtargetの履歴のみ更新 | KeyboardSnapControllerTests.testCrossDisplayKeyboardPlacementRecordsTargetLayoutAndZoneOnly |
| ドラッグretain失効後のticket/gate/lease解放 | DragSnapTests.testInvalidationDuringHistoryLeaseAcquireAlwaysFinishesCommitAndReleasesSource。drag-revision-focused-2で成功 |
| baseline中通知、new launch、PID再利用、partial snapshot | NewWindowMonitorTestsのstartup・queued baseline・stale termination・seen cap |
| overflow一回、seen解放、停止後再登録禁止 | NewWindowMonitorTestsのinbox・callback flood・overflow cleanup stop |
| readiness有限再試行、絶対offset、AX予算 | NewWindowMonitorTests.testTemporaryReadinessUsesFiveAbsoluteRetryOffsetsDespiteAXTime / expired deadline・dedicated mover |
| mismatchはassignment/保存なし、成功対照 | NewWindowMonitorTestsのfinite mismatch・successful automatic restore |
| cancel後backend完了までticketとinflight枠維持 | NewWindowMonitorTestsのcancel setter・cancelled observation episodes / shutdown drain |
| 設定defaults・FIFO・未知キー・保存失敗Retry | AppHistorySettingsと既存settings persistenceを通る追加テスト |
| 権限撤回・単一timer・明示Retry | HistoryPermissionMonitorTests / lifecycle接続の追加検証 |
| Space change、restoreのみオフ、monitorオフ | NewWindowMonitorTestsのterminal/Space・restore toggle |

中間の修正前失敗→修正後成功にはretain取消、manual stale readback、seen容量guardの回帰ログがある。各一時変更の復元SHAも保存している。

mismatch対照は同じ対象テストで `mismatch-guard-baseline-pass.log` が1件成功、`framesMatch`判定だけを外した `mismatch-guard-negative-assertion.log` がassignmentのXCTAssertFalseとlease解放待機の2 assertions失敗、復元後 `mismatch-guard-restored-pass.log` が1件成功。コンパイル失敗の旧negativeログは不採用。`mismatch-guard-restoration.txt` の前後SHAはともに `0b60af24f3a080b6bf254a66ac5e69741882be491df430a6c682efd30e6c8eca` で一致し、親も現在のAutoRestoreController.swiftのSHAを照合済み。最終全suiteでも同対象が成功した。

## GUI・実機確認

GUIは統括側で最終ビルド固定後にCUAから実施予定。この作業セッションではGUI操作・画像取得・実AX配置を実施していない。統括からFinderのAX tree取得可能との連絡はあるが、AppAlignの動作確認結果ではない。Macのロック状態を推測しない。

| 項目 | 状態 |
|---|---|
| 新設定画面とスクリーンショット | 未検証・未取得 |
| 外部アプリの新規ウィンドウ実復元 | 未検証 |
| 同一アプリ複数ウィンドウ・更新権移譲 | fixture検証対象。実アプリ未検証 |
| 実手動Place/Restore・監視オフ | 未検証 |
| 権限撤回/再許可/明示Retry・quit取消 | fixture検証対象。OS設定操作未検証 |
| MacBook Air M1 + Dellの画面間配置 | 未検証 |
| macOS 26受け入れ | 未検証。統括側予定環境はmacOS 27 |

起動用アプリは `/Users/a2c/.codex/worktrees/bd3b/AppAlign/build/DerivedData/Build/Products/Debug/AppAlign.app`。最終manifestの実行ファイルSHAと照合して引き渡す。fixtureの成功は実機完了の証拠を代替しない。

## 親レビュー・終了時確認

要件38/40、所有権・取消24/25、検証23/25、証拠・報告10/10、**95/100・重大指摘0**。保存FIFO、raw revision、owner移譲、capture世代、成功境界、seen lease、overflow epoch、backend未完了時の枠保持と終了drain、権限Retry gateを親がレビューした。分割後の可視性とPBX参照も修正し、全264メソッドの実行と元220件の保持を独立確認した。

GUI・実AX・実機画面構成は未検証のため減点に反映し、確認済みとは主張しない。ローカルコミットとclean状態を最終manifestへ記録してworktreeを保持する。公開操作、CI、実機の受け入れは統括の判断に委ねる。

- sourceFingerprint: `6ffa1502618f5d733804a73a6d89474dbfef3b124e20dcc7c5cdb1c9ec189c4b`
- 起動対象: `/Users/a2c/.codex/worktrees/bd3b/AppAlign/build/DerivedData/Build/Products/Debug/AppAlign.app`
- 実行ファイルSHA-256: `63e83d6d72a142d1ed97d01202cfae83c88c6dd9bdb4ff913bdec5b70f7dac19`
- GUI確認手順: `/private/tmp/issue-11-gui-handoff.md`
- 日本語PR本文案: `/private/tmp/issue-11-pr-body-ja.md`
