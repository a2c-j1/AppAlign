# Issue #12 ローカル検証記録

状態: **bundle helper接続済み・ローカル自動検証完了、実採用は未許可**。Spaceごとの永続化と実行時解決はproviderが安定IDを検証できた場合だけ有効になる。production SkyLight backendはbundle内helperへ接続済みだがadoption gateはfalseで、Space A/Bの実機配置・GUI確認は未完了。対象ホストはユーザー訂正後のmacOS 27.0.1 / build 26A434 / arm64 M1 + Dell。元のmacOS 26想定からの変更である。Issueの実機受け入れ完了を意味しない。

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

productionのSkyLight backendは後述のbundle helperへ接続済みで、adoption gateはfalse。隔離CLI `scripts/space-probe.py` とnative helper `scripts/space-probe.swift` は実装した。作業セッションで公開CoreGraphics APIから外部display UUID `D16814E6-E4F8-4D8F-0857-D6964E3302DB`を取得し、builtin=0、オンライン外部display 1台だった。内蔵display UUIDは取得結果として記録していない。Dellの製品名も列挙APIからは取得していない。

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

追加のread-only資料確認では、`space-renamer`の固定commit [`c0b2878659f6594f2894bac8b1c467f439b2df94`のActiveSpaceReader.swift](https://github.com/noobomancer/space-renamer/blob/c0b2878659f6594f2894bac8b1c467f439b2df94/Sources/SpaceRenamerCore/ActiveSpaceReader.swift#L16)が別名の`CGSCopyManagedDisplaySpaces`結果から先頭displayのSpaces辞書の`uuid`をStringで読む実例を確認した。ただし欠落・不正型を空文字に統合し、[SpacesPlistParser.swift](https://github.com/noobomancer/space-renamer/blob/c0b2878659f6594f2894bac8b1c467f439b2df94/Sources/SpaceRenamerCore/SpacesPlistParser.swift#L11)は空文字をprimaryへ変換する。[READMEの安定性主張](https://github.com/noobomancer/space-renamer/blob/c0b2878659f6594f2894bac8b1c467f439b2df94/README.md#L74)もprimary display対象で、今回の外部display・OS・SLS query・raw 1の意味を保証しない。`hs._asm.undocumented.spaces`の固定commit [`75e5be3b16e532a307aab043c3c73646716a67f1`のCGSSpace.h](https://github.com/asmagill/hs._asm.undocumented.spaces/blob/75e5be3b16e532a307aab043c3c73646716a67f1/CGSSpace.h#L64)のuuid記載はSpace作成APIのoptions辞書用であり、列挙schemaの保証ではない。今回probeには別key・別関数を追加せず、raw 1をprimaryや生成IDへ置換していない。

列挙版のSwift 6 helper/純粋fixtureのcompileと実行、`python3 scripts/test_space_probe.py`の10 testsが成功した。64/65件、前後集合変化、重複UUID、固定schema、既知項目失敗の非成功扱い、実生成型のnull保持を含む。ログは`/private/tmp/issue12-space-probe-null-encoding-tests.log`。親レビューは97/100点、重大不具合0件。

- ローカル環境: macOS 27.0.1 (build 26A434)、arm64 M1 + Dell、Xcode 26.5。テストbuildはXcode付属MacOSX 26.5 SDKを使用する。
- Probe Swift 6 compile: `"$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" -swift-version 6 -sdk "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk" -target arm64-apple-macosx26.0 scripts/space-probe-core.swift scripts/space-probe.swift -o build/issue-12-probe/space-probe` 成功。buildはgitignore対象。
- `python3 scripts/test_space_probe.py`: 8 tests成功。内容はpure OS guard、wrapper guard、CLI help/引数、2秒timeout childとstdout-close childのkill/reap、過大stdout、native CF metadata/type/UUID/current-ID fixtures、wrapper exact-key/type-kind/UUID検証。実private queryは上記の拡張probe2回のみ。A-B-AおよびOS再起動照合は未実行。
- `scripts/test.sh`: 前commitのR12-4版でbuild/smoke成功、287 tests passed / 0 failures / 0 skips。ログ `/private/tmp/issue12-r12-4-test-script.log`、xcresult `/Users/a2c/.codex/worktrees/issue-12-space/AppAlign/build/issue-3-evidence/AppAlignTests-20261018T080202Z-99815.xcresult`。probe専用追加ではAppAlign/AppAlignTests/pbxproj/scripts/test.shを変更せず、287 testsを再実行していない。R12-4のfocused testは1 test passed、ログ `/private/tmp/issue12-r12-4-focused-retry.log`、xcresult `/private/tmp/issue12-r12-4-focused-retry.xcresult`。
- `swiftformat AppAlign AppAlignTests --lint --config .swiftformat`: 93 files checked、0 files need formatting。
- `swiftlint lint --config .swiftlint.yml`: 93 files、0 violations / 0 serious。
- `/Users/a2c/.local/bin/semgrep scan --config .semgrep.yml --error AppAlign AppAlignTests scripts/space-probe.swift scripts/space-probe.py scripts/test_space_probe.py`: 4 rules、56 applicable targets、0 findings。probe pathsも明示指定した。既存ruleのpath filterは`AppAlign/**/*.swift`なので、実際にrule適用されたのはその範囲。
- `git diff --check`: 成功。新規Swift source/test filesは`AppAlign.xcodeproj/project.pbxproj`のapp/test sourcesへ登録し、公式suiteでcompile・実行した。

## 非同期接続基盤（実SkyLight未採用）

非同期checkpoint `4fd6c06`で同期`SpaceProvider.refresh(displays:)`を廃止し、`makeRefreshRequest`、cacheを変更しない`nonisolated async readCandidate`、同期`publish`へ分離した。`ReadOnlySpaceBackend.snapshot`はasync throws契約で、戻り値はSendable。同期private IPCや子process待機は専用直列workerへ隔離し、queryとchild終了/reapを完了してからreturnする契約とした。このcheckpointではhelper実体を未接続とし、後述のbundle同梱checkpointで接続した。`DisplayConfigurationController`は独立した既定1秒deadlineを持ち、実行中1件と最新待機要求1件に集約する。

要求には`callbackEpoch`、`pendingRevision`、display snapshotを固定する。結果到着時にepoch、`validity.revision.configuration`とのrevision一致、sleep/構成変更待ち状態、再採取displayとの一致を確認し、古い結果はcache更新前に破棄する。合格時だけawaitなしでSpace cache、`DisplayProvider.publish`、`layout.displaysDidPublish`を更新し、最後に`validity.publishConfiguration(revision:)`でgateを開く。取得中の同期呼出しは最後にpublish済みのdisplayを返す。

timeoutはbackendのTaskGroup競争で実装せず、独立deadline taskで最新要求をfallbackする。実backend呼出しのrunning枠は実際のreturnまで保持し、取消し・timeout・shutdownでは解放しない。同時実処理1件と最新待機1件に制限し、待機時間も受付時の絶対deadlineへ含める。待機中の期限切れは実行せずfallbackして枠から外す。古い結果は同revisionでもtimeout後に採用せず、epoch不一致でも実処理枠の後始末だけは行う。shutdown→cancelQuitもこの占有規則を維持する。再試行は新しいinvalidationとして扱う。

最新要求の失敗は同revisionのdisplayと`degradedScoped`を一括反映し、古い失敗で新しい成功を上書きしない。通知callbackによる同期ticket無効化、shutdown時のepoch無効化、cancelQuit時の再取得を維持する。shutdown中はpollを含む新規要求・publishを拒否する。起動時は`startAfterPersistentLoad`の構成gate初期化を履歴監視・hotkey受付より先に置く。本体変更は`SpaceProvider.swift`、`DisplayConfigurationController.swift`、`AppAlignApp.swift`の3ファイルに限定し、実SkyLight採用gateはfalseを維持した。

focused検証は`SpaceProviderTests`と`DisplayConfigurationControllerTests`の19 tests成功、xcresultは`/private/tmp/issue12-space-focused-8.xcresult`。保留continuation backendでMainActor応答、同fingerprintへ戻るA→B→Aの古い失敗拒否、候補read時のcache不変、intent変更の拒否、最新失敗、取消非対応readのtimeout、待機期限切れによる追加call抑止、display再採取不一致からpoll再取得、sleep/wake、shutdown中poll拒否、cancelQuit後の単一slot再開を検証した。callback同期ticket無効化の既存検証も維持した。既存テストのprovider呼出しは候補read/publishへ適応し、assertionを弱めず非同期公開を待つようにした。

### 非同期checkpointの最終検証

2026-10-18にsourceをfreezeした後の` scripts/test.sh `が、中断後も最後まで完了していたことを2026-10-22の再開時に確認した。通常macOS build、294 tests / 0 failures / 0 skips、bundle executable・bundle identifierのsmokeが成功している。ログは`/private/tmp/issue12-async-test-script.log`、元xcresultは`build/issue-3-evidence/AppAlignTests-20261018T134542Z-41167.xcresult`。`xcresulttool get test-results summary`でもmacOS 27.0.1 / build 26A434 / arm64上の294件Passedを照合した。source/testの更新時刻はこの実行前で、再開後はレビューと文書更新のみ。重複実行を避け、10/22に新しいビルド・全suiteを開始していない。

実行コマンドは` scripts/test.sh > /private/tmp/issue12-async-test-script.log 2>&1 `で、通常チェックそのものだった。当時のbuildはarm64・x86_64を含み、test実行はarm64だった。jobs 2を指定した実行と誤記しない。今後新たに実行する場合はユーザー指定のarm64・jobs 2・同時ビルド1件を適用し、その制限を通常コマンドとの差として記録する。高負荷時にこの検証buildだけを一時停止し、プレビュー起動後に同じPID群を再開して完走した。

同差分のSwiftFormatは93 files / 0 formatting changes、SwiftLintは93 files / 0 violations、Semgrepは4 rules / 56 applicable AppAlign files / 0 findingsで成功。Semgrepログは`/private/tmp/issue12-async-semgrep.log`。親の最終評価は要件34/35・非同期安全34/35・回帰検証24/25・保守性4/5の96/100、重大指摘0件。実SkyLight採用false、実機Space別の利用可否はこの自動検証では確認していない。

試用中のprimary `build/preview/AppAlign.app`は変更・終了・再署名していない。統括が重複appをLS登録解除・退避した後、再開時にこのworktreeの`build/DerivedData/Build/Products/Debug/AppAlign.app`が存在しないことを確認した。ビルドを追加していないため重複appも再生成していない。xcresultと他DerivedDataは保持している。#13は対象外、#29の入力監視・権限初期化・再署名は行っていない。

## bundle同梱・backend接続checkpoint（2026-10-22）

`AppAlignSpaceHelper`をSwift 6のcommand-line tool targetとして追加した。既存の` scripts/space-probe.swift `と` scripts/space-probe-core.swift `をbuild時にcompileし、appのtarget dependencyとExecutables Copy Files phase（CodeSignOnCopy）により`Contents/MacOS/AppAlignSpaceHelper`へ同梱する。helperの機能は変更していない。productionは`Bundle.main.url(forAuxiliaryExecutable:)`でこの実体を使い、repo相対パス、PATH探索、Python、実行時の再compileには依存しない。

`SpaceHelperProcessRunner`は専用の直列DispatchQueueで子processを起動し、通常9-field JSONだけを最大2KBまで読む。実OS major 27/build 26A434とhelperの独立guardを維持する。backend側のdeadlineは最大250ms、controller側は既定1秒である。複数displayは全体残時間からreserveを引き、残画面数で予算を分ける。取消しはflagだけを更新し、最大25msのpollで専用queueが検出する。timeout・過大出力・取消しでは起動した直接childだけを終了し、実終了/reapとpipe cleanup後にreturnする。stdout先行closeでもdeadlineを維持し、取消し側が回収済みPIDへsignalする経路を持たない。

decoderはexact keys、型、OS/build/display、adoption false、exit/error、正UInt64 raw ID、type/kind、UUID文法を検査する。通常type 0のUUID candidateだけを永続ID候補として返す。raw ID、順番、primary sentinelは使わない。fullscreenや候補欠落はscoped値を返さず、取得不能なそのdisplayのcurrentだけをdegradedにする。他SpaceのUUID欠落を理由に全列挙成功を要求しない。production factoryから接続済みだが、backend自身もgate falseを検査して子起動を止める。

明示的な`Refresh Displays`だけは`force: true`で新revisionの取得を要求する。通常poll・キー・drag・auto経路はforce falseのまま。同じdisplayでhelperが一度失敗してdegradedになっても、回復後にユーザーがRefreshを押してvalidatedへ戻れる。自動pollの度にgateを閉じて再取得する方式にはしていない。

署名を既定のまま有効にし、ビルド同時1件・arm64・jobs 2・非並列testingで次の単一コマンドを実行した。通常の` scripts/test.sh `との差は、arm64とjobs数の明示、並列testing無効化、別DerivedData/resultBundleの使用である。`CODE_SIGNING_ALLOWED=NO`は使わず、Team・証明書・権限設定は変更していない。

```sh
xcodebuild -project AppAlign.xcodeproj -scheme AppAlign -destination 'platform=macOS,arch=arm64' -jobs 2 -parallel-testing-enabled NO -derivedDataPath /private/tmp/issue12-backend-derived-data -resultBundlePath /private/tmp/issue12-backend-tests-20261022.xcresult ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
```

最初の実行でapp/helper buildと全303 testsが成功し、0 failures / 0 skipsだった。通過後の再実行はしていない。xcresult summaryでもmacOS 27.0.1 / 26A434 / arm64 / 303 Passedを確認した。ログは`/private/tmp/issue12-backend-test-20261022.log`、xcresultは上記path。新規8 testsはdecoder、正常dummy応答、strict schema/identity/数値型、timeout/EOF、過大出力、取消しとreap、混在display予算、閉gate/host不一致/helper欠落を確認する。既存controller testへ同displayの失敗→通常poll不再試行→明示force→回復の1件を追加した。既存version/layoutを含む回帰も同suiteで実行した。

appとhelperの`codesign --verify --deep --strict`（helper単体は`--verify --strict`）が成功し、両実行ファイルはarm64だった。同梱helperの`--help`はexit 0で、private query前に終了する動作を確認した。bundle identifierは`jp.a2c.AppAlign`。補助的に読んだversionメタデータ2 keysは新生成物と既存試用版の両方に元から存在せず、この差分では追加・変更していない。実private queryは実行していない。

SwiftFormatは95 files / 0 changes、SwiftLintは95 files / 0 violations、Semgrepは4 rules / 57 applicable AppAlign files / 0 findingsで各exit 0。ログは`/private/tmp/issue12-helper-swiftformat-20261022.log`、`/private/tmp/issue12-helper-swiftlint-20261022.log`、`/private/tmp/issue12-helper-semgrep-20261022.log`。既存Semgrepのpath filterはhelper sourceを含まず、helperは既存固定sourceのまま別targetでcompile・署名確認している。親の最終評価は要件30/30・境界安全34/35・検証24/25・保守9/10の97/100、重大指摘0件。

新生成appだけを`lsregister -u`で登録解除し、`/private/tmp/issue12-retired-verification-20261022/AppAlign.app.retired`へ退避した。退避後も両署名を再確認済み。元のDerivedDataのAppAlign.appは残しておらず、xcresultと他DerivedDataは保持した。検証helper・buildの残留processなし。既存試用版は変更・終了・再署名していない。

ユーザーはOS再起動を明示保留した。統括から伝達された10/22の通常41/58のUUID一致は同じboot内の観測であり、再起動安定性ではない。実A→B→Aと再起動後の同一性は未確認で、adoption gateはfalseのまま。#13は対象外、#29は修正保留を維持する。

## 実機で必要な確認

1. 対象Macで`sw_vers -productVersion; sw_vers -buildVersion; uname -m`を確認する。公開CoreGraphicsの`CGGetOnlineDisplayList` + `CGDisplayCreateUUIDFromDisplayID`でM1内蔵画面とDellのdisplay UUIDを得て、UUIDと接続構成を作業記録に残す。
2. 統括・ユーザーがGUIでSpace A→B→Aを確認する際、各切替後に各display UUIDで`python3 scripts/space-probe.py --expected-os-major 27 --expected-build 26A434 --display-uuid <DISPLAY_UUID>`を実行する。9-field JSONのraw ID/type/UUID candidateが同じ論理Spaceへどう対応するか記録する。probe自体はSpaceを切り替えない。
3. 同じ論理Spaceでprobeプロセス再起動とOS再起動の前後を照合する。raw ID/type/UUID candidateとdisplay UUIDの対応がA-B-A、process restart、OS restartで再現し、失敗条件でdegraded fallbackすることを確認するまで採用しない。API利用不可時はdegradedの基本配置だけを使い、history/auto/Space保存を止め、復帰後は保存済みcommon/Space assignmentへ戻ることを確認する。
