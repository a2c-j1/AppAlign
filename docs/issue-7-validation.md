# Issue #7 ローカル検証記録

対象は CGEventTap による入力監視とタイトルバードラッグの検出境界。Overlay、ゾーン選択、drop時のウィンドウ配置は含まない。起点は #6 統合 `d7a802e80dd73902e8e6c2600c754e6f4be98d02`、作業ブランチは `feature/issue-7-drag-detection`。

## 実装と権限

- 検出は既定で無効。設定の有効化・Retry操作時だけ Input Monitoring / Accessibility の理由を説明して要求する。設定UIの検証中に新しいOS権限は付与していない。
- listen-only の session event tap は入力をそのまま返す。callback は値の取出しと短い同期mailbox操作のみ。AX、描画、JSON保存、入力抑制、入力注入を行わない。
- mailbox は通常256件と例外terminal枠1件。隣接moveだけをcoalesceし、down/up/flags/button/障害の境界を保持する。overflowは黙って継続せず、世代を失効して取消・監視停止とする。
- hover/down captureは同時1件、最新pending hover/down各1件、frame readも同時1件と最新point1件。lease解放は1件ずつ処理し、cleanup待ち2件からcaptureを止める。現在のbaselineとin-flight結果の解放を含める有限上限は4件。
- AX通信は共有AccessibilityWindowRuntimeの専用serial executorで行う。直接AXUIElement通信は既存WindowManagement.swift境界に集約する。keyboard ownerとdrag leaseを分け、drag取消がkeyboardの初回矩形を消さない。
- session、input run/gesture、AX request、環境の世代を区別する。古い結果は新しいsessionやgateを変更せず、自身のleaseだけを解放する。公開Space通知、display fingerprint、対象消失、権限撤回、tap中断、Esc、停止、終了で取消する。
- quit停止と利用者のenabled意図を分離する。終了取消時は権限・ボタン解放を確認して新しいdownから再開する。共有runtimeのshutdownはアプリ所有者がdrag資源の解放後に行う。

## 判定と開始前矩形

押下要素・ancestor role・所属window・上辺の候補領域と、実測originのpointer追従、size安定を併用する。text、tab、web/content、ボタン、splitter、辺・角のresizeを拒否する。候補からmovingへは2回の整合する観測を必要とする。判定値は現在の実装上の仮定であり、4アプリの実機確認済み仕様ではない。

hover prewarmは1件のcacheを保持する。開始前に実測した矩形と採取時刻、対象token、狭い押下領域、display/input/environment世代、公開AX通知のrevision履歴を保存する。downでfreshnessとidentityを検証し、後着の検証応答では開始前sampleを上書きしない。通知非対応・登録失敗は検証済cacheとして扱わない。

- 100ms freshnessと最大10Hzのprewarmは、保持するsnapshotの古さと問い合わせ量を制限する初期値。実測macOSの成功率から導いた値ではなく、定数を変更して同じ陽性・陰性matrixを再検証する余地がある。
- coalesce後もgestureの最初のdrag時刻を保持する。cacheなしで移動後に取得した矩形を初期矩形と偽らない。
- 有限16件のrevision履歴を使い、押下前のmove、resize、destroy、programmatic write、履歴欠落を拒否する。押下後の正常なpointer-following moveは開始前sampleを維持して検証する。
- 元down地点が移動後のcontentへ入った場合は最新pointerで一度だけ再検証する。対象やsizeの確定失効を再試行で成功扱いにしない。
- 公開AX通知には入力イベントとの同期保証がなく、WindowMoved/WindowResized通知は操作終了時に届く。押下直前の別原因の移動通知が遅れた場合、押下後native移動から厳密に区別できない。記録する初期矩形はprovenanceを持つ実測pre-down sampleであり、押下瞬間との厳密一致を保証しない。

## ローカル検証

2026-10-07、macOS 27.0.1 / Xcode 26.5で最終ソースを検証した。

- `scripts/test.sh`: universal Debugビルド（arm64 / x86_64）、全134テスト成功、失敗0・スキップ0、bundle smoke成功。既存93件に41件を追加した。
- XCTest結果: `build/issue-3-evidence/AppAlignTests-20261007T025741Z-70457.xcresult`。親セッションと統括の双方がxcresulttoolで134件成功を独立確認した。
- SwiftFormat 0.63.1: 43ファイル中、整形が必要なファイル0。
- SwiftLint 0.65.1: 警告・違反0。
- Semgrep 1.176.0: 既存4ルール、29ファイル、finding 0・error 0。ルールの変更・抑制は行っていない。
- 統括のローカル実装レビュー: 93/100（要件36/40、安全25/25、検証22/25、報告10/10）、重大指摘0。公開前の実機・GUI確認は下記の未検証項目として残す。

追加テストは、固定期待イベント列、overflow、最初のdrag時刻、1万件のmove/down/hoverと遅延AX barrier、up-before-hit、旧lease解放中の次down、旧frameエラー、非同期cleanupのbackpressure、通知revisionの時系列、cacheなし・古い・別token・size/環境変更、flags-only更新、全terminal、quit取消、permission/tap失敗を扱う。fake試験を実機成功と記載しない。

## GUI・実機確認の状態

2026-10-07、cua_replで今回のapp絶対パスを指定してUI取得を試みたが、`Computer Use server error -10005: timeoutReached`となった。GUI表示・スクリーンショットは未検証、画像は取得していない。OS権限を付与せず、GUIの制約をローカル検証と区別する。

後続受け入れでは Finder / Safari / Chrome / Ghostty ごとに、通常・速いタイトルバードラッグの陽性と、text選択・tab操作・content drag・4辺/4角resizeの陰性を記録する。Chrome tab分離は別の観察項目とし、未確認を合格扱いにしない。上下/負座標/Retinaと非Retinaで、CGEvent/AXとDisplaySnapshotのglobal logical pointが一致し二重変換されないことも確認する。

画面の添付手順: 検出無効、必要権限不足、監視中、停止/Retryの設定表示をcua_replで取得する。個人情報を含まない対象を用い、同じcommitの画面であることを確認してPRへ添付する。実Input Monitoring・Accessibilityの付与/撤回を伴う実機試験は、既存権限と利用者操作の範囲を確認して行う。
