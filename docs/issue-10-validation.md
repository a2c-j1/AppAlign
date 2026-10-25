# Issue #10 ローカル検証記録

検証日: 2026-10-15（Asia/Tokyo）。基点: developの `147ca613befbe2d834343d614a0274541c2da179`（#9 PR #26統合、統合CI 38529116378 success）。ブランチ: `feature/issue-10-zone-selection`。

状態は **LOCAL_READY**。公開push・PR作成・マージ・Issue完了処理は未実施。実機・GUIの未検証を、ローカル自動検証の成功と区別する。

## 変更した動作

- Shiftによるsnap許可と独立した範囲修飾キー（既定Option）で、開始・終了ゾーンのbounding boxに完全包含されるゾーンを選び、隙間を含む結合矩形へ配置する。
- Smallest/Largest/Positional/ClosestCenterの4方式。tieは安定したlayout順。ClosestCenterの75は論理point²。候補IDの連続性を仮定しない。
- 修飾キーを静止中に押下・解除した場合と最終mouseUpを反映する。画面移動ではanchorをresetし、構成変更では#9のcancelを保持する。
- キーボードの方向拡張・逆方向縮小・modifier解除・通常移動への復帰。元矩形とRestoreを保持し、modifier監視が利用できない場合は拡張を停止する。
- 保存済みlayoutへの専用Carbon hotkey。ドラッグ中の切替はmutation前に旧ticketを失効させ、元の物理dragと窓leaseを維持して同じカーソルから再選択する。
- InputMonitorとlayout commandは同lockの受理FIFOへ入る。切替を越えて移動をcoalesceしない。保証対象は受理順であり、異なるproducerの物理timestamp順ではない。
- FIFO保存、未知設定キー保持、未保存割当のRetry。別layoutのcatalog-only保存成功によって、失敗した割当を保存済み扱いにしない。
- 任意wheel切替は未実装・OFF・有効化不可。listen-only tapを変更せず、通常scrollを通す。

## 自動検証

| 項目 | 結果・証拠 |
|---|---|
| macOS build / XCTest / bundle smoke | scripts/test.sh成功。220件成功、失敗0、skip0、expected failure0 |
| 最終結果束 | build/issue-10-evidence/AppAlignTests-final-active-owner-20261015.xcresult |
| 実行ログ | build/issue-10-evidence/full-suite-final.log |
| 親による独立結果確認 | xcresulttool summary: Passed、220/220。parent-review-xcresult-summary.jsonはdevice IDを除いて保存 |
| 既存テスト保持 | 基点の182 test methodsがすべて残る。assertion減少0、新skip0。baseline-test-preservation.json |
| SwiftFormat | 親再確認で0/67 files require formatting。parent-review-format.log |
| SwiftLint | 親再確認で0 violations / 0 serious、67 files。parent-review-lint.log |
| Semgrep | 親再確認で4 rules、42 source files（未追跡を含む）、0 findings。parent-review-semgrep.log |
| patch / project | git diff --check成功、PBX plutil -lint成功 |
| 実行環境 | MacBook Air / arm64、macOS 27.0.1（26A434）、Xcode 26.5 |

最終結果束はUTCを含む既存scriptの命名を維持する。上記ファイルはignoredのbuild配下に置き、コミット内容のソース・テスト・project hashをmanifest.jsonへ記録する。

## 要件と回帰証拠

| 要件・境界 | 主要テスト |
|---|---|
| 完全包含・spacingの隙間・非連続ID | DragZoneSelectionTests.testRangeUsesBoundingBoxFullContainmentAndKeepsSpacingGaps |
| 4重なり方式・tie | DragZoneSelectionTests、ZoneSelectionBoundaryTests |
| 四辺半開境界、75直前/一致/直後、3候補非推移fold | ZoneSelectionBoundaryTestsの3件 |
| 最終flagsとmodifier独立 | DragFinalReleaseAcceptanceTests、Shift OFF中のrange解除/再押下対照 |
| layout切替直後drop | 実detector→onWillEnd→lease handoff→runtimeを通るaccepted switch barrierと即upテスト |
| 保存失敗後もmoving維持 | DragFinalReleaseAcceptanceTestsのquick save failure recoveryと新layout drop |
| 世代・lease・古いcleanup・gate/slot | DragSnapTests、PlacementValidityTests、RuntimeWindowOwnershipTestsの既存barrierを保持 |
| keyboard拡張/縮小/解除、監視利用不可 | KeyboardSnapControllerTests、KeyboardLifecycleTests |
| Carbon callback→同じ入力FIFO | LayoutHotkeysTests.testCarbonRouteAndInputCoreShareAcceptedSwitchReleaseOrder |
| route世代・停止・競合・解除失敗 | LayoutHotkeysTests、GlobalHotkeysTests |
| move coalesceのcontrol境界・overflow・世代 | OrderedInteractionTests |
| flags/drag購読寿命・古いqueued downの拒否 | FlagsSubscriptionTests、InputMonitorLifecycleTests |
| 設定round-trip・未知キー | KeyboardSettingsTests、PersistenceTests |
| failed quick assignment→catalog成功→Retry | LayoutEditorConcurrencyTests.testCatalogSaveKeepsFailedQuickAssignmentPendingForRetry |
| 複数画面と構成ABA | MultiDisplayTests、DisplayConfigurationControllerTestsを維持 |

catalog-only成功後の未保存割当消失は、追加テストの4 assertionsで修正前の失敗を確認し、修正後に同テストと全体suiteの成功を確認した。Retryは最新catalogとassignmentをまとめて保存するため、後から保存したlayout定義も保持する。

## 実機・GUIの未検証matrix

GUI操作・画像取得はCUAのみ。2026-10-15にビルド済みAppAlignの絶対パスをCUA getAppへ渡したが、Macがロックされ、自動unlockもできない旨が返った。AppAlignのAX tree・設定画面・Overlay・実配置・画像を取得できていない。別GUI経路、shell撮影、追加の権限付与には迂回していない。

| 実機項目 | 状態・再確認方法 |
|---|---|
| 設定画面・新しいbinding UI | 未検証。ロック解除済みMacでCUA対象app snapshot/screenshotを取得 |
| Shift+Option、静止flags、最終up | 未検証。外部appの実タイトルバーdragで押下/解除を確認 |
| Canvas重なり4方式と結合配置 | 未検証。保存済みCanvas/25-50-25 Gridを用い、actual readbackとhighlightを確認 |
| native Carbon hotkey→即drop | 未検証。実キー入力の受理順と新layoutのdropを確認 |
| modifier解除・keyboard拡張/縮小・normal/Restore | 未検証。外部appで4方向と解除を確認 |
| MacBook Air M1 + Dellの画面境界 | 未検証。この接続構成・画面配置を確認して横断dragとresetを実行 |
| 権限撤回/復旧・quit取消 | 未検証。既存Input Monitoring/Accessibility境界の実操作を確認 |
| 通常scroll・ゾーン非表示scroll | 未検証。wheel設定OFFの実app scrollを確認 |
| GUI/dragのスクリーンショット | 未取得。CUAで取得できない場合は未検証を維持 |

fixtureによる成功は、native input、実AX配置、MacBook Air M1 + Dell接続での完了証拠を代替しない。Issue #10の実機完了扱い・公開操作は統括の判断に委ねる。

## 親レビュー・終了時確認

要件39/40、安全24/25、検証23/25、報告9/10、**95/100・重大欠落0**。計画とコードを照合し、mutation前失効、元lease保持、受理FIFO、最終up、layout順tie、既存drain、pending保存とRetryを確認した。

220件の最終suite後、このworktreeのAppAlign/test/xcodebuild残留がないことを確認。CUAの試行後もAppAlign残留を確認していない。worktreeはLOCAL_READY報告とレビューのため保持する。

## 523319eへの追加レビュー対応

統括レビューで見つかった拡張処理の取消・履歴スコープを追加修正した。統括の最終受け入れは別途必要であり、この記録は作業セッション内のLOCAL_READYを示す。

- history resetと同時に拡張専用ticketを同期失効する。通常配置ticketには作用しない。preflightがtrueで返った後からbeginWriteまでの実runtime境界でもsetter開始・後続書込・成功確定を拒否する。
- handleで操作世代・所有modifier・pending IDを捕捉し、focusedWindow取得とretainのawaitを跨いで保持する。解除済み世代を新しいattemptとして採用しない。pending ownerはID照合で終了し、成功履歴のownerと寿命を分ける。
- 初回・後続flagsとも現在の操作が所有するmodifierで判定する。別方向のmodifier成立は解除を隠さず、無関係なmodifierの解除は所有chordを取り消さない。古いsampleが押下を含まない場合も現在sampleで取消判定する。
- 同じPIDでも別window tokenを操作・eligibility probeで観測した場合は拡張履歴をresetする。A/B両方のoriginal Restoreと所有権は保持する。自身の対象変更resetでは新対象への最初の拡張を正常に開始する。未観測のfocus遷移を検出したとは主張しない。

| 追加検証 | 証拠 |
|---|---|
| 実runtimeのpreflight後barrier | RuntimeWindowOwnershipTests.testNavigationResetInvalidatesExtensionTicketAtRuntimeBeginWriteBoundary |
| scoped reset / 通常配置の成功対照 | KeyboardExtensionRaceTests、KeyboardLifecycleTests.testHistoryResetDoesNotInvalidateNormalPlacementTicket |
| capture/retain待機中の解除と保持対照・Restore | KeyboardExtensionAwaitTestsの4件 |
| 同PID A→B→A、eligibilityのみB観測 | KeyboardExtensionRaceTestsの2件。A/B Restoreのactual frameも照合 |
| 初回release・保持・方向別custom chord交替/無関係解除 | KeyboardSnapControllerTestsの追加3件 |
| 既存208件の保持 | review-208-test-preservation.json: missing 0、assertion減少0、新skip0 |
| 修正前失敗 | keyboard-review-race-before-fix.log、actual-runtime-reset-race-before-fix.log |
| 最終結果 | full-suite-final.log、parent-review-xcresult-summary.json: 220/220、失敗0、skip0 |

追加差分の作業セッション内レビュー: 競合遮断39/40、ticket分離25/25、対照テスト24/25、報告9/10、**97/100・重大指摘0**。既存lint閾値・Semgrepルールを維持し、追加テストを2ファイルへ分割してtest targetへ登録した。
