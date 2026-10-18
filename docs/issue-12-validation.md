# Issue #12 ローカル検証記録

状態: **ローカル実装・自動検証**。Spaceごとの永続化と実行時解決はproviderが安定IDを検証できた場合だけ有効になる。production SkyLight backendはread-only stubのままで、Space A/Bの実機配置・GUI確認は未完了。対象ホストはユーザー訂正後のmacOS 27.0.1 / build 26A434 / arm64 M1 + Dell。元のmacOS 26想定からの変更である。Issueの実機受け入れ完了を意味しない。

## 実装・自動テストの範囲

- `commonOnly` は共通assignment、既存履歴学習、自動復元を維持する。`validatedScoped` はdisplay UUID + 検証済みSpace IDでassignment/historyを分離する。`degradedScoped` は共通の基本配置を表示しつつ、履歴・自動復元とSpaceへの永続保存を止め、一時overrideを保持する。
- schema 1の共通データ移行、schema 2の複合scope key、未知形式・構造不正データの原本保護、既知catalog参照のprune/high-watermark、editor/quickの遅延保存delta、Space通知時の配置ticket無効化をテストする。
- `SpaceProviderTests` と controller統合テストでA/B assignment・履歴分離、commonOnly履歴/autoの継続、degraded時の停止と一時配置、復帰、editor/quickのawait競合を検証する。`testDegradedSpaceSkipsAutomaticMoveAndPreservesCommonHistory` は実AutoRestoreController経路で移動と履歴更新がないことを確認し、`testSuccessfulAutomaticRestoreKeepsAssignmentAndRuntimeHistoryLease` はcommonOnlyの既存動作を確認する。通知callback同期無効化は`testSpaceCallbackInvalidatesTicketSynchronouslyAndMainActorPublishesAfterward`で確認する。

## Space APIの安全境界

公開の[`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)はSpace切替通知で、通知自体はactive Space IDを提供しない。

read-onlyで取得した実装資料として、`koekeishiya/yabai`が`asmvik/yabai`へ転送されたリポジトリのcommit [`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/commit/dd845723416f5fe92af49fad5ebab00369e07edd)（2026-06-14、commit messageはmacOS 26.6 Apple Silicon対応）を固定した。同commitの[`src/misc/extern.h`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L42)は`extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);`を宣言する。[`src/display.c`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L101)の`display_uuid`は`CGDisplayCreateUUIDFromDisplayID`からUUID文字列を作り、[`display_space_id`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L179)がその文字列と`g_connection`を渡して`uint64_t`を受け、UUID文字列を`CFRelease`する。これは存在する第三者実装とcall-site上の型・呼出し順の根拠であり、AppleのABI一次資料ではない。macOS 26.6の記述も現対象macOS 27.0.1 ABIを保証しない。所有権契約、失敗値、IDの安定性を保証しないため、採用済みABIとは扱わない。

productionのSkyLight backendは引き続きread-only stubで、adoption gateはfalse。隔離CLI `scripts/space-probe.py` とnative helper `scripts/space-probe.swift` は実装し、Swift 6でcompileした。統括が公開CoreGraphics APIで外部display UUID `D16814E6-E4F8-4D8F-0857-D6964E3302DB`（builtin=0、外部1台）を取得し、Dellの製品名はこの列挙APIからは得ていない。

統括が次のコマンドを独立したhelperプロセスで2回実行し、両方exit 0、JSON結果は同一だった: `python3 scripts/space-probe.py --expected-os-major 27 --expected-build 26A434 --display-uuid D16814E6-E4F8-4D8F-0857-D6964E3302DB`。両方の結果は`{"adoption":false,"build":"26A434","displayUUID":"D16814E6-E4F8-4D8F-0857-D6964E3302DB","error":null,"kind":"unknown","osMajor":27,"rawSpaceID":"41"}`。通常のCtrl+Right/Left入力後も41のままで、A/B切替成功とは扱わず、原因も特定していない。これはhelperプロセス再起動をまたぐ一致だけを示す。Space A/B切替、OS再起動後の安定性、kind、製品adoptionは未検証であり、結果を適用せずgateをfalseのまま保つ。GUIによるSpace操作の完了確認はしていない。

CLIは`--expected-os-major 27 --expected-build 26A434 --display-uuid UUID`を必須とする。wrapperは`sw_vers`、native helperは`ProcessInfo`と`kern.osversion`から実機値を独立に読み、allowlist major 27とbuild完全一致を両方確認するまで`dlopen`/`dlsym`/private callへ進まない。入力は実OS値を偽装できず、major 27以外は受け付けない。query候補は固定sourceにある`SLSMainConnectionID() -> int`と`SLSManagedDisplayGetCurrentSpace(int, CFStringRef) -> uint64_t`の2関数のみ。Swift側はこの2つの`dlsym`結果だけをsource記載signatureへcastする。UUIDはCoreFoundation UUIDとして検証し、raw ID 0は失敗とする。kindは根拠未確認のため常に`unknown`、出力adoptionは常にfalse。childのstdoutは2KBまでをwrapperがparse/sanitizeし、stderrは破棄する。2秒超過時はwrapper自身が起動したchild PIDのみkillしwait/reapする。GUIまたはSpace A/Bは操作しない。

このCLIは、対象major 27/build 26A434を明示指定した隔離観測用である。対象build以外、symbol不在、connection失敗、UUID不正、raw ID 0、output不正、またはtimeoutではCLI失敗を記録する。実取得はexit 0 / error nullでもkindはunknownであり、Spaceの意味とID安定性を確認できていないためadoption条件を満たさない。IDのprocess/OS再起動安定性とdisplay UUID対応の一意性が確認されるまでscoped adoptionは不可。

## 環境と検証

- ローカル環境: macOS 27.0.1 (build 26A434)、arm64 M1 + Dell、Xcode 26.5。テストbuildはXcode付属MacOSX 26.5 SDKを使用する。
- Probe Swift 6 compile: `"$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" -swift-version 6 -sdk "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk" -target arm64-apple-macosx26.0 scripts/space-probe.swift -o build/issue-12-probe/space-probe` 成功。buildはgitignore対象。
- `python3 scripts/test_space_probe.py`: 6 tests成功（pure guard一致/不一致、wrapper guard前compile拒否、CLI help/引数/UUID、2秒timeout childとstdout-close childのkill/reap、過大stdoutの非転送）。native helperへexpected major 26を指定した実ホストguard試験は`unsupported_os_major`で終了し、raw IDなし・adoption false。別途、統括が実ホスト27/build26A434で上記read-only queryを2回実行し、両方rawSpaceID `41` / kind `unknown` / adoption `false` を記録した。GUI A/B切替とOS再起動照合は未実行。
- `scripts/test.sh`: R12-4を含む最新版でbuild/smoke成功、287 tests passed / 0 failures / 0 skips。ログ `/private/tmp/issue12-r12-4-test-script.log`、xcresult `/Users/a2c/.codex/worktrees/issue-12-space/AppAlign/build/issue-3-evidence/AppAlignTests-20261018T080202Z-99815.xcresult`。R12-4のfocused testは1 test passed、ログ `/private/tmp/issue12-r12-4-focused-retry.log`、xcresult `/private/tmp/issue12-r12-4-focused-retry.xcresult`。
- `swiftformat AppAlign AppAlignTests --lint --config .swiftformat`: 93 files checked、0 files need formatting。
- `swiftlint lint --config .swiftlint.yml`: 93 files、0 violations / 0 serious。
- `/Users/a2c/.local/bin/semgrep scan --config .semgrep.yml --error AppAlign AppAlignTests scripts/space-probe.swift scripts/space-probe.py scripts/test_space_probe.py`: 4 rules、56 applicable targets、0 findings。probe pathsも明示指定した。既存ruleのpath filterは`AppAlign/**/*.swift`なので、実際にrule適用されたのはその範囲。
- `git diff --check`: 成功。新規Swift source/test filesは`AppAlign.xcodeproj/project.pbxproj`のapp/test sourcesへ登録し、公式suiteでcompile・実行した。

## 実機で必要な確認

1. 対象Macで`sw_vers -productVersion; sw_vers -buildVersion; uname -m`を確認する。公開CoreGraphicsの`CGGetOnlineDisplayList` + `CGDisplayCreateUUIDFromDisplayID`でM1内蔵画面とDellのdisplay UUIDを得て、UUIDと接続構成を作業記録に残す。
2. GUIでSpace A/Bを切り替える前後に、各display UUIDを引数として`python3 scripts/space-probe.py --expected-os-major 27 --expected-build 26A434 --display-uuid <DISPLAY_UUID>`を実行する。stdoutのJSONだけを保存し、raw IDが切替に追従するか、kindは`unknown`のままであることを記録する。probeはSpaceを切り替えない。
3. 同じ論理Spaceを保ったままprobeプロセス再起動とOS再起動の前後でraw ID/display UUIDの対応を比較する。kind unknownまたはID安定性未確認なら採用しない。GUIによるA/B往復と手動配置確認は統括・ユーザーの協調後に実施する。API利用不可時はdegradedの基本配置だけを使い、history/auto/Space保存を止め、復帰後は保存済みcommon/Space assignmentへ戻ることを確認する。
