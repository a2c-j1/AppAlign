# Issue #12 ローカル検証記録

状態: **ローカル実装・自動検証**。Spaceごとの永続化と実行時解決はproviderが安定IDを検証できた場合だけ有効になる。現在のproduction SkyLight backendはread-only stubで、stable Space IDを供給しないため、実機でのSpace A/B対応や配置は未確認。GUI、macOS 26、M1 + Dell構成も未検証であり、Issueの実機受け入れ完了を意味しない。

## 実装・自動テストの範囲

- `commonOnly` は共通assignment、既存履歴学習、自動復元を維持する。`validatedScoped` はdisplay UUID + 検証済みSpace IDでassignment/historyを分離する。`degradedScoped` は共通の基本配置を表示しつつ、履歴・自動復元とSpaceへの永続保存を止め、一時overrideを保持する。
- schema 1の共通データ移行、schema 2の複合scope key、未知形式・構造不正データの原本保護、既知catalog参照のprune/high-watermark、editor/quickの遅延保存delta、Space通知時の配置ticket無効化をテストする。
- `SpaceProviderTests` と controller統合テストでA/B assignment・履歴分離、commonOnly履歴/autoの継続、degraded時の停止と一時配置、復帰、editor/quickのawait競合を検証する。`testDegradedSpaceSkipsAutomaticMoveAndPreservesCommonHistory` は実AutoRestoreController経路で移動と履歴更新がないことを確認し、`testSuccessfulAutomaticRestoreKeepsAssignmentAndRuntimeHistoryLease` はcommonOnlyの既存動作を確認する。通知callback同期無効化は`testSpaceCallbackInvalidatesTicketSynchronouslyAndMainActorPublishesAfterward`で確認する。

## Space APIの安全境界

公開の[`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)はSpace切替通知で、通知自体はactive Space IDを提供しない。

read-onlyで取得した実装資料として、`koekeishiya/yabai`が`asmvik/yabai`へ転送されたリポジトリのcommit [`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/commit/dd845723416f5fe92af49fad5ebab00369e07edd)（2026-06-14、commit messageはmacOS 26.6 Apple Silicon対応）を固定した。同commitの[`src/misc/extern.h`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L42)は`extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);`を宣言する。[`src/display.c`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L101)の`display_uuid`は`CGDisplayCreateUUIDFromDisplayID`からUUID文字列を作り、[`display_space_id`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L179)がその文字列と`g_connection`を渡して`uint64_t`を受け、UUID文字列を`CFRelease`する。これは存在する第三者実装とcall-site上の型・呼出し順の根拠であり、AppleのABI一次資料ではない。所有権契約、失敗値、IDの安定性、macOS 26の対象buildでの互換性を保証しない。したがって採用済みABIとは扱わない。

productionのSkyLight backendは引き続き呼出し・symbol lookupとも未実施のstubで、adoption gateはfalse。未検証OS上でprivate関数を呼び出したり、欠けたIDを合成したりしていない。今後の調査は次の隔離probe条件を満たす専用CLIで行う。probeの実装・実行はまだ行っていない。

1. **固定入力と隔離:** 対象Mac上の別プロセスとして実行し、起動時にOS version/buildと接続中display UUIDを引数または標準入力で受ける。対応するmacOS 26 build以外は呼出し前に終了する。AppAlign本体からロード・呼出しせず、画面・window・process配置を書き換えるAPIをリンク対象にしない。
2. **read-only候補:** 上記sourceの候補`SLSMainConnectionID() -> int`でconnection IDを取得し、`SLSManagedDisplayGetCurrentSpace(int, CFStringRef) -> uint64_t`だけを候補として検証する。UUIDは入力値をCFUUIDとして検証し、戻り値0、symbol不在、型不一致、呼出し失敗を成功IDへ変換しない。probeの出力はOS build、入力display UUID、raw Space ID、確認できたSpace kind（未確認なら`unknown`）、error codeだけとし、アプリ名・window情報などは出力しない。
3. **失敗条件:** symbol不在、OS build不一致、UUID変換失敗、0/欠落ID、戻り値型またはkind不明、displayとの対応不整合、2秒以内に完了しない場合はprobe失敗として記録し、その環境のgateはfalseのままにする。失敗時に推測値・前回値・任意IDへfallbackしない。
4. **安定性と採用:** macOS 26の正確なbuildを記録し、M1 + Dellの複数displayで、Space A/B往復、fullscreen、display追加/除去、sleep/wake、probeプロセス再起動、OS再起動の前後にread-onlyの結果を照合する。同じ論理SpaceのIDが永続assignment keyに必要な範囲で安定し、display UUIDとの対応が一意で、全失敗条件でdegraded fallbackすることを確認する。一次資料または固定sourceとOS buildごとの再現記録、実機結果、回帰testsを親がレビューするまでgateを開かない。IDが再起動で変わる、型/kindが不明、またはOS build間でsignature差があれば採用せずcommon/degraded動作を維持する。

## 環境と検証

- ローカル環境: macOS 27.0.1 (build 26A434)、Xcode 26.5。テストbuildはXcode付属MacOSX 26.5 SDKを使用する。
- `scripts/test.sh`: build/smoke成功、286 tests passed / 0 failures / 0 skips。ログ `/private/tmp/issue12-test-script-final-3.log`、xcresult `/Users/a2c/.codex/worktrees/issue-12-space/AppAlign/build/issue-3-evidence/AppAlignTests-20261018T074237Z-94171.xcresult`。
- `swiftformat AppAlign AppAlignTests --lint --config .swiftformat`: 93 files checked、0 files need formatting。
- `swiftlint lint --config .swiftlint.yml`: 93 files、0 violations / 0 serious。
- `/Users/a2c/.local/bin/semgrep scan --config .semgrep.yml --error AppAlign`: 4 rules、56 tracked targets、0 findings。新規Spaceソース5パスも明示指定して再scanし、4 rules / 4 applicable targets / 0 findings（`SpaceProvider.swift`はcentralize-private-api rule自身のexclude対象）。ログは `/private/tmp/issue12-semgrep-final.log` と `/private/tmp/issue12-semgrep-new-sources.log`。
- `git diff --check`: 成功。新規Swift source/test filesは`AppAlign.xcodeproj/project.pbxproj`のapp/test sourcesへ登録し、公式suiteでcompile・実行した。

## 実機で必要な確認

1. macOS 26 + M1 + Dellで、検証済みSpace IDのread-only取得とA/B切替を確認する。
2. 同一displayのA/Bに別layoutを保存し、画面表示、manual/keyboard/drag/autoの対象、履歴が切替時に混ざらないことを確認する。
3. API利用不可時にdegradedの基本配置だけが残り、history/auto/Space保存が止まること、復帰後に保存済みcommon/Space assignmentへ戻ることを確認する。
