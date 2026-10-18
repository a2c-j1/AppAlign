# Issue #12 ローカル検証記録

状態: **ローカル実装・自動検証**。Spaceごとの永続化と実行時解決はproviderが安定IDを検証できた場合だけ有効になる。production SkyLight backendはread-only stubのままで、Space A/Bの実機配置・GUI確認は未完了。対象ホストはユーザー訂正後のmacOS 27.0.1 / build 26A434 / arm64 M1 + Dell。元のmacOS 26想定からの変更である。Issueの実機受け入れ完了を意味しない。

## 実装・自動テストの範囲

- `commonOnly` は共通assignment、既存履歴学習、自動復元を維持する。`validatedScoped` はdisplay UUID + 検証済みSpace IDでassignment/historyを分離する。`degradedScoped` は共通の基本配置を表示しつつ、履歴・自動復元とSpaceへの永続保存を止め、一時overrideを保持する。
- schema 1の共通データ移行、schema 2の複合scope key、未知形式・構造不正データの原本保護、既知catalog参照のprune/high-watermark、editor/quickの遅延保存delta、Space通知時の配置ticket無効化をテストする。
- `SpaceProviderTests` と controller統合テストでA/B assignment・履歴分離、commonOnly履歴/autoの継続、degraded時の停止と一時配置、復帰、editor/quickのawait競合を検証する。`testDegradedSpaceSkipsAutomaticMoveAndPreservesCommonHistory` は実AutoRestoreController経路で移動と履歴更新がないことを確認し、`testSuccessfulAutomaticRestoreKeepsAssignmentAndRuntimeHistoryLease` はcommonOnlyの既存動作を確認する。通知callback同期無効化は`testSpaceCallbackInvalidatesTicketSynchronouslyAndMainActorPublishesAfterward`で確認する。

## Space APIの安全境界

公開の[`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)はSpace切替通知で、通知自体はactive Space IDを提供しない。

read-onlyで取得した実装資料として、`koekeishiya/yabai`が`asmvik/yabai`へ転送されたリポジトリのcommit [`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/commit/dd845723416f5fe92af49fad5ebab00369e07edd)（2026-06-14、commit messageはmacOS 26.6 Apple Silicon対応）を固定した。以下はこのcommit内の宣言と実callsiteを照合した結果で、AppleのABI一次資料ではなく、macOS 27.0.1でのABI保証や安定性の証明ではない。

- [`src/misc/extern.h:9`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L9)と[`L42`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L42)は`int SLSMainConnectionID(void)`と`uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid)`を宣言する。[`src/yabai.c:143`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/yabai.c#L143)がconnection IDを初期化し、[`src/display.c:101-109`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L101-L109)がCG display IDからUUID文字列を作る。[`display.c:179-187`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L179-L187)はUUID文字列とconnection IDで現在Space IDを取得する。
- [`src/misc/extern.h:56`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L56)は`int SLSSpaceGetType(int cid, uint64_t sid)`、[`src/space.c:88-100`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space.c#L88-L100)は戻り値`0=user`, `4=fullscreen`, `2=system`として分類する。その他は`unknown`として扱う。
- [`extern.h:60`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L60)は`CFArrayRef SLSCopyManagedDisplaySpaces(int cid)`を宣言する。[`display.c:197-213`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L197-L213)と[`225-249`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/display.c#L225-L249)は返却されたCFArrayを使い終わると`CFRelease`する。callsiteはdisplay dictionaryの`Display Identifier`をdisplay UUIDと照合し、その`Spaces`配列の各dictionaryから`id64`をCFNumberとして読む。probeは入力UUIDに一致するdisplayが一件、そこにある`id64`のうち現在IDとの一致が一件あることを要求する。未確認のcurrent Space keyやUUID keyは使わず、重複・欠損・誤型・Boolean・小数・負数・0・UInt64範囲外を失敗にする。
- [`extern.h:57`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L57)は`CFStringRef SLSSpaceCopyName(int cid, uint64_t sid)`を宣言する。[`view.c:995,1039`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/view.c#L995)は値を保持して破棄時にreleaseし、[`space_manager.c:1166-1195`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1166-L1195)は値を比較用に使い保持分をreleaseする。probeはCFStringがUUID文法に合う場合だけ`spaceUUIDCandidate`へ出し、それ以外の名前文字列は出力しない。この候補は同一性・安定性を保証しない。

この固定sourceは候補関数のsignature、返却値の利用・release、id64の型を示す第三者実装である。対象OS buildのABI一次資料や安定ID契約ではないため、製品backendへの採用根拠にはしない。

productionのSkyLight backendは引き続きread-only stubで、adoption gateはfalse。隔離CLI `scripts/space-probe.py` とnative helper `scripts/space-probe.swift` は実装した。作業セッションで公開CoreGraphics APIから外部display UUID `D16814E6-E4F8-4D8F-0857-D6964E3302DB`を取得し、builtin=0、オンライン外部display 1台だった。内蔵display UUIDは取得結果として記録していない。Dellの製品名も列挙APIからは取得していない。

拡張probeにより統括が次のコマンドを独立したhelperプロセスで2回実行し、両方exit 0、9-field JSONは同一だった: `python3 scripts/space-probe.py --expected-os-major 27 --expected-build 26A434 --display-uuid D16814E6-E4F8-4D8F-0857-D6964E3302DB`。結果は`{"adoption":false,"build":"26A434","displayUUID":"D16814E6-E4F8-4D8F-0857-D6964E3302DB","error":null,"kind":"user","osMajor":27,"rawSpaceID":"41","rawSpaceType":0,"spaceUUIDCandidate":"06497333-89E6-B6A1-90A2-D67FCC9F9348"}`。親は専用probe子プロセスの残留がないことも確認した。これは同一Spaceでのhelper process 2回の一致だけで、A-B-A切替やOS再起動後の安定性は証明しない。統括は別途、手動Space切替中に120 samples / 70秒でraw ID `1`→`41`、error 0を観測したが、どのSpaceがA/Bかを固定した照合ではなく、新probeのkind/UUID candidateを含むA-B-A証拠ではない。過去の旧probeはraw ID `41`を2回観測し、kind `unknown`だった。旧probeの7-field結果と今回の9-field結果は別時点の記録である。

CLIは`--expected-os-major 27 --expected-build 26A434 --display-uuid UUID`を必須とする。wrapperは`sw_vers`、native helperは`ProcessInfo`と`kern.osversion`から実機値を独立に読み、allowlist major 27とbuild完全一致を両方確認するまで`dlopen`/`dlsym`/private callへ進まない。入力は実OS値を偽装できず、major 27以外は受け付けない。private関数は固定sourceの`SLSMainConnectionID() -> int`、`SLSManagedDisplayGetCurrentSpace(int, CFStringRef) -> uint64_t`、`SLSSpaceGetType(int, uint64_t) -> int`、`SLSCopyManagedDisplaySpaces(int) -> CFArrayRef`、`SLSSpaceCopyName(int, uint64_t) -> CFStringRef`のみ解決する。`Copy`の+1結果は`takeRetainedValue`で一度消費し、CFArray/CFDictionary内部の値はborrowed参照として保持せず、CFTypeID確認後に読む。現在IDを前後で取得し、一致しなければ`space_changed_during_probe`とする。JSONは`osMajor`, `build`, `displayUUID`, `rawSpaceID`, `kind`, `error`, `adoption`, `rawSpaceType`, `spaceUUIDCandidate`の9 fieldsのみ。kindは固定sourceの0/2/4をuser/system/fullscreenへ写し、その他はunknown + CLI error。raw id64はCFNumber・非Boolean・非小数を確認後、文字列表現からUInt64へ厳密変換する。`spaceUUIDCandidate`はCopyName値がUUID文法の時だけ出し、space名文字列は出力しない。wrapperはexact keys、型/kind整合、UUID/UInt64範囲、exit/errorの整合を検証する。adoptionは常にfalse。child stdoutは2KBまで、stderrは破棄し、2秒超過時はwrapper自身が起動したchild PIDのみkillしwait/reapする。CLI自身はSpaceを切り替えない。

このCLIは対象major 27/build 26A434を明示指定した隔離観測用である。OS/build不一致、symbol不在、connection/metadata照合失敗、UUID不正、raw ID 0、未知type、output不正またはtimeoutはCLI errorとして扱う。一方、exit 0 / error nullであっても、IDの意味・A-B-A/OS再起動安定性・kindとUUID candidateの安定性を確認し製品adoption条件を満たすまでgateはfalseのままにする。現観測のcandidateはUUID形式だが、一致性・安定性は未証明である。

## 環境と検証

### 対象displayの有限列挙baseline

2026-10-18T13:04:04Zに、上記CLIへ`--list-spaces`を付け、対象displayの実metadata由来IDだけを照会した。再起動前の生JSONを[`evidence/issue-12-space-baseline-26A434.json`](evidence/issue-12-space-baseline-26A434.json)へ保存した。対象display UUIDは`D16814E6-E4F8-4D8F-0857-D6964E3302DB`、現在IDは`41`。同じdisplayに次の3件が存在し、いずれもtype 0 / kind userだった。

| raw ID | UUID候補 | 項目error |
| --- | --- | --- |
| 58 | `5EA7DC96-5689-1D28-6AF8-DB244D30E11E` | null |
| 41 | `06497333-89E6-B6A1-90A2-D67FCC9F9348` | null |
| 1 | null | `invalid_space_uuid` |

raw 1と41が同じdisplayの通常desktopであることは確認できたが、raw 1はCopyNameのUUID文法検査を満たさなかった。nil、空値、非UUID文字列のどれかは、この出力では区別していない。両Spaceの異なるUUID候補は証明できず、任意IDへの補完はしない。全体は`invalid_space_uuid` / exit 3で、adoption falseを維持する。A→B→Aと再起動安定性も未証明である。

列挙はmanaged display entryと対象Spacesを各64件に制限し、超過・重複ID・既知UUID重複・型不正を失敗とする。前後のcurrent IDと対象ID集合が一致した時だけ表を返す。各項目はID/type/kind/UUID候補/errorの5 keysを持ち、候補欠落はnullで記録する。未知typeやUUID欠落を含む表は成功扱いしない。通常モードは9 fields/2KB、列挙成功または項目失敗の診断モードはspacesを加えた10 fields/16KB。専用childの2秒timeoutとkill/reap、strict OS/build、stderr破棄を維持する。

拡張中、最初の列挙はUUID欠落で全表なしの失敗、診断追加後はtimeoutと出力検証失敗を各1回観測した。後者はSwiftのnil key省略を明示nullへ修正し、実生成型を使ったserialization fixtureで検証した。最終実測は上記の全3件を返した。最終実測前の自動承認レビューは一度期限切れでコマンド未開始となり、許可された再試行で取得した。これらの失敗を有効なSpace対応表としては扱わない。

固定yabai revisionの`display.c`、`space.c`、`space_manager.c`、`view.c`、`misc/extern.h`の確認範囲では、Space辞書の別UUID keyを読むcallsiteは見つからず、推測したmetadata keyは追加していない。確認範囲外を含む不存在は断定しない。

列挙版のSwift 6 helper/純粋fixtureのcompileと実行、`python3 scripts/test_space_probe.py`の10 testsが成功した。64/65件、前後集合変化、重複UUID、固定schema、既知項目失敗の非成功扱い、実生成型のnull保持を含む。ログは`/private/tmp/issue12-space-probe-null-encoding-tests.log`。親レビューは97/100点、重大不具合0件。

- ローカル環境: macOS 27.0.1 (build 26A434)、arm64 M1 + Dell、Xcode 26.5。テストbuildはXcode付属MacOSX 26.5 SDKを使用する。
- Probe Swift 6 compile: `"$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" -swift-version 6 -sdk "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk" -target arm64-apple-macosx26.0 scripts/space-probe-core.swift scripts/space-probe.swift -o build/issue-12-probe/space-probe` 成功。buildはgitignore対象。
- `python3 scripts/test_space_probe.py`: 8 tests成功。内容はpure OS guard、wrapper guard、CLI help/引数、2秒timeout childとstdout-close childのkill/reap、過大stdout、native CF metadata/type/UUID/current-ID fixtures、wrapper exact-key/type-kind/UUID検証。実private queryは上記の拡張probe2回のみ。A-B-AおよびOS再起動照合は未実行。
- `scripts/test.sh`: 前commitのR12-4版でbuild/smoke成功、287 tests passed / 0 failures / 0 skips。ログ `/private/tmp/issue12-r12-4-test-script.log`、xcresult `/Users/a2c/.codex/worktrees/issue-12-space/AppAlign/build/issue-3-evidence/AppAlignTests-20261018T080202Z-99815.xcresult`。probe専用追加ではAppAlign/AppAlignTests/pbxproj/scripts/test.shを変更せず、287 testsを再実行していない。R12-4のfocused testは1 test passed、ログ `/private/tmp/issue12-r12-4-focused-retry.log`、xcresult `/private/tmp/issue12-r12-4-focused-retry.xcresult`。
- `swiftformat AppAlign AppAlignTests --lint --config .swiftformat`: 93 files checked、0 files need formatting。
- `swiftlint lint --config .swiftlint.yml`: 93 files、0 violations / 0 serious。
- `/Users/a2c/.local/bin/semgrep scan --config .semgrep.yml --error AppAlign AppAlignTests scripts/space-probe.swift scripts/space-probe.py scripts/test_space_probe.py`: 4 rules、56 applicable targets、0 findings。probe pathsも明示指定した。既存ruleのpath filterは`AppAlign/**/*.swift`なので、実際にrule適用されたのはその範囲。
- `git diff --check`: 成功。新規Swift source/test filesは`AppAlign.xcodeproj/project.pbxproj`のapp/test sourcesへ登録し、公式suiteでcompile・実行した。

## 製品backendへの非同期接続案（未実装）

現行の`SpaceProvider.refresh(displays:)`はMainActorで同期backendを呼ぶため、private IPCや子process待機を直接追加しない。`DisplayConfigurationController`が既存の`beginInvalidation`後に取得を要求し、専用の直列workerと有限timeoutで取得したSendable結果をMainActorへ返す。実行中1件と最新要求1件に集約する。

要求には`callbackEpoch`、`pendingRevision`、display snapshotを固定する。結果到着時にepoch、`validity.revision.configuration`とのrevision一致、sleep/構成変更待ち状態、再採取displayとの一致を確認し、古い結果はcache更新前に破棄する。合格時だけawaitなしでSpace cache、`DisplayProvider.publish`、`layout.displaysDidPublish`を更新し、最後に`validity.publishConfiguration(revision:)`でgateを開く。取得中の同期呼出しは最後にpublish済みのdisplayを返す。

最新要求の失敗は同revisionのdisplayと`degradedScoped`を一括反映し、古い失敗で新しい成功を上書きしない。通知callbackによる同期ticket無効化、shutdown時のepoch無効化、cancelQuit時の再取得を維持する。起動時は`startAfterPersistentLoad`の構成gate初期化を履歴監視・hotkey受付より先に置く。変更境界は`SpaceProvider.swift`、`DisplayConfigurationController.swift`、`AppAlignApp.swift`と関連テスト。遅延fake backendで応答中のMainActor応答性、A→B→Aの遅い結果拒否、fallback、lifecycle、display変化、polling集約を検証する。今回は設計記録のみで製品sourceを変更していない。

## 実機で必要な確認

1. 対象Macで`sw_vers -productVersion; sw_vers -buildVersion; uname -m`を確認する。公開CoreGraphicsの`CGGetOnlineDisplayList` + `CGDisplayCreateUUIDFromDisplayID`でM1内蔵画面とDellのdisplay UUIDを得て、UUIDと接続構成を作業記録に残す。
2. 統括・ユーザーがGUIでSpace A→B→Aを確認する際、各切替後に各display UUIDで`python3 scripts/space-probe.py --expected-os-major 27 --expected-build 26A434 --display-uuid <DISPLAY_UUID>`を実行する。9-field JSONのraw ID/type/UUID candidateが同じ論理Spaceへどう対応するか記録する。probe自体はSpaceを切り替えない。
3. 同じ論理Spaceでprobeプロセス再起動とOS再起動の前後を照合する。raw ID/type/UUID candidateとdisplay UUIDの対応がA-B-A、process restart、OS restartで再現し、失敗条件でdegraded fallbackすることを確認するまで採用しない。API利用不可時はdegradedの基本配置だけを使い、history/auto/Space保存を止め、復帰後は保存済みcommon/Space assignmentへ戻ることを確認する。
