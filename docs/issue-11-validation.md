# Issue #11 ローカル検証記録

状態: **LOCAL_READY（ローカル受け入れ）**。基点develop `d52e1c8ac08773c39f74a991431eaabc5f6b2355`、ブランチ `feature/issue-11-app-zone-history`。最終HEADは `build/issue-11-evidence/manifest.json` に記録する。公開push・PR作成・マージ・Issue完了処理は未実施。GUI・実AX配置・M1+Dell・macOS 26の受け入れは未確認。

## Issue本来の受け入れ項目

自動テストはfixtureと実runtimeの注入境界による証拠であり、実アプリでの成功を主張しない。

| 受け入れ項目 | コード・自動テスト証拠 | 実機証拠・未確認 |
|---|---|---|
| 成功した配置だけを保存し、失敗・中断は保存しない | AppHistoryLayoutIntegrationと各配置の成功境界。manual stale readback / drag invalidation / finite mismatched readback / successful automatic restoreを全suiteで実行 | 実アプリのPlace/Restoreと保存比較は未確認 |
| 同一アプリの複数窓でも履歴を不意に上書きしない | AppHistoryCoordinatorのowner管理。OwnerMovesOnlyAfterSuccess / RuntimeDestroyObserverTransfersOwnerWithoutPersistingUntilNextPlacement | 実アプリW1/W2での更新権移譲は未確認 |
| 設定ONで新規窓を復元し、OFFでは動かない | NewWindowMonitorとAutoRestoreController。startup baseline / restore toggle / successful automatic restore。R23容量満杯時のclose+new、R24 OFF→ON後baselineも実行 | 設定画面・初期値・実新規窓の復元は未確認 |
| AX未準備・無効履歴は有限に終了 | 絶対retry offset、episode期限、R25 bounded retain。TemporaryReadinessUsesFiveAbsoluteRetryOffsetsDespiteAXTime / expired enumeration / terminal candidate / 今回の期限2テスト | OS応答遅延・権限撤回下の実動作は未確認 |
| layout削除・画面未接続・無効ZoneIDを扱う | AppZoneHistoryPersistenceのprune / stale layout / out-of-range / sparse merged grid検証とrestoreTargetの接続画面選択。未接続画面履歴を保持 | 外部画面の抜き差し・削除後の実復元は未確認 |

## 今回の再レビュー修正

- R23: 128 records全owned時の容量不足を明示し、closed seen lease解放後、元の期限内で最大1回再走査する。実AccessibilityWindowRuntimeのtoken/所有権を使い、64history+64seen、close/new一通知、重複候補なし、空きなしで有限終了、partialでcloseなしを確認した。容量・CFEqual・owned eviction方針は維持。
- R24: 旧baselineのawait中にOFF→ONしても、同じdrainが新epochのbaseline要求を処理する。追加通知なしでobserver一つ、既存窓を候補化せず、新規窓のみ一回候補化する。stopのみでは再開しない。
- R25: autoのhistory retainへepisode残期限と200msの小さい絶対期限を伝播する。actor待機後の期限切れはobserver登録なしで失敗しpending leaseを解放する。通常retainの1秒期限は維持。

R23とR24は旧処理へ戻した際のコンパイル成功・assertion失敗をそれぞれr23-capacity-red.log、r23-drain-old-red.logへ保存した。最新対象5件はr23-focused-green.logで成功。途中のcompile失敗、fixture待機条件の失敗、premature-greenは赤・最終成功の証拠に採用しない。

## 最終自動検証

- 公式scripts/test.sh: macOS build・269テスト成功、失敗0、skip0、expected failure0・bundle smoke成功。r23-scripts-test-final.logと最終xcresultをmanifestへ結び付けた。
- 親が実行ログとソース269メソッドを照合。旧264実行IDの欠落0、新規5件を確認。developの元220件も保持し、assertion減少0、新skip0。
- SwiftFormat / strict-no-cache SwiftLint / Semgrep / project / diffの最終結果はmanifestの成果物に記録。設定・閾値・検証scriptの変更なし。
- source freezeと全suite後の99入力・実行ファイルSHAが一致。ローカルコミット内の各入力SHAとも一致し、clean状態を確認した。
- 実行環境: arm64、macOS 27.0.1（26A434）、Xcode 26.5（17F42）。macOS 26の結果ではない。

旧e5aaa0eの264件検証とmismatch guard負対照は `build/issue-11-evidence/e5aaa0e-snapshot/` に保全し、relocation.jsonで対応付けた。旧結果を今回の全suite成功の代用にしていない。

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

## 実機で必要な確認

1. 設定初期値OFFと監視のみONで無移動を確認し、設定画面を撮影する。
2. 外部アプリを明示配置して学習し、自動復元ONで新規窓が一度だけ復元、OFFで動かないことを確認する。
3. 同一アプリW1/W2の別ゾーン配置、W1を閉じた後のW2配置で履歴の更新権を確認する。
4. Place/Restore、監視OFF→ON、権限撤回/再許可/明示Retryを確認する。
5. layout削除・無効ZoneID・外部画面未接続時に不正移動せず、再接続時の扱いを確認する。

統括は最終.app（実行ファイルSHA `898850e6dc265d594e3e9866394d973e870d802c2bf2a012a96e4f70b0e84592`）へのCUA exactpath接続を再試行し、`-10005 timeoutReached`となった。実パスから起動したPID37914をTERMし、対象残留なしを確認したとの報告を受けた。画面・実配置は未確認。旧.appの試行もtimeoutで、PID89356停止・残留なしの報告を受けている。

## 引き渡し

- 親レビュー: R23 29/30、R24 20/20、R25 24/25、検証15/15、証拠・範囲10/10、98/100・重大指摘0。採点は差分の受け入れ補助であり、実機確認の代替ではない。
- sourceFingerprint: `35c227542671c4ef38d268a318837dbf17ebc4d70c666d2ac5870357fe0ca9fc`
- 起動対象: `/Users/a2c/.codex/worktrees/bd3b/AppAlign/build/DerivedData/Build/Products/Debug/AppAlign.app`
- 実行ファイルSHA-256: `898850e6dc265d594e3e9866394d973e870d802c2bf2a012a96e4f70b0e84592`
- 最終manifest: `build/issue-11-evidence/manifest.json`
- GUI確認手順: `/private/tmp/issue-11-gui-handoff.md`
- 日本語PR本文案: `/private/tmp/issue-11-pr-body-ja.md`
