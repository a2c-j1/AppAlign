# Issue #6 キーボード配置・復元の検証

## 操作仕様

- 番号指定のactionは実際のZoneIDを保持する。表示は既存の安全な`displayNumber`に合わせ、表示衝突時だけIDで区別する。
- 番号順modeでは実在IDの昇順で前後・左右移動する。上下のbindingは登録しない。
- 位置modeでは最新の実ウィンドウ矩形中心を起点に方向・角度・距離から選ぶ。前後actionは左右方向として扱う。同scoreはID順。同中心は通常探索の候補から除外するが、明示ID指定で配置できる。
- 循環OFFの端では移動しない。ONではWorkArea幅・高さだけ逆方向へ起点を移して探索し、現在ゾーンしか選べない場合は移動しない。
- 対象ウィンドウの画面から適用済み定義を取得する。設定UIの選択画面や未適用draftは使わない。
- 初回書込み前の矩形を保存し、読み戻し成功時だけ配置を確定する。部分失敗・復元失敗でも原矩形を保持する。

## 回帰テストの対応

| 対象 | 証拠となるテスト |
| --- | --- |
| 4方向、角度評価、循環、疎ID、Int.max、同点 | `ZoneNavigatorTests` |
| 設定型値、未知キー、無効・重複binding | `KeyboardSettingsTests` |
| 複数回の配置後の初回矩形復元、復元失敗再試行 | `KeyboardSnapControllerTests` |
| 登録probe中の終了、古いcallback、再有効化、OS予約・登録失敗、解除失敗 | `GlobalHotkeysTests` |
| 設定失敗→editor成功→終了再試行、古いRetry→新設定、未知キー再読込 | `KeyboardIntegrationTests` |
| 対象画面B、Save/Apply分離、session画面 | `KeyboardIntegrationTests` |
| 取得・書込み・結果待ちでの終了/無効化、同PID別window、権限・layout変化 | `KeyboardLifecycleTests` |
| 終了取消後のRestore、所有済みprobe token、session上限、部分読み戻し失敗 | `KeyboardLifecycleTests` |

既存のunhosted XCTest、`scripts/test.sh`のbuild/test/bundle smoke、Swift 6、SwiftFormat、SwiftLint、Semgrepの設定を維持する。

## 確認済みの自動検証

2026年10月7日、Xcode 26.5 / macOS 27.0.1で実行した。

- `scripts/test.sh`: macOSビルド・93 XCTest（既存58＋追加35）・bundle smoke成功。失敗0、スキップ0。
- 結果bundle: `build/issue-3-evidence/AppAlignTests-20261007T015243Z-48860.xcresult`。`xcresulttool`で93成功を親が確認した。
- SwiftFormat: AppAlign/AppAlignTestsの34ファイル、整形変更不要。
- SwiftLint: 同34ファイル、既存strict設定で違反0。
- Semgrep: ステージ済みの24アプリSwiftソース、既存4ルール、finding 0。
- `git diff --cached --check`: 問題なし。

親の最終品質ログは`/private/tmp/issue6-final-format.log`、`issue6-final-lint.log`、`issue6-final-semgrep.log`。GUI確認とは別の証拠として扱う。

## キー配送の限界

無効なbinding・対象外と判定済みの状態では登録を解除する。登録解除に失敗した場合は、未解放のキーが消費され得ることを表示して再試行する。

Carbonが既に受信した登録済みキーを、AX失敗後に通常アプリへ戻す保証はない。フォーカス・権限通知の遅延もあるため、対象外キーの配送を完全には保証しない。OSの入力とAX書込みを一つの原子的操作として扱わない。

## 実機確認とスクリーンショット

GUI操作・Finder/Safari/Chrome/Ghosttyへの実配置・キー配送・スクリーンショットは未検証。`cua_repl`でビルド済みアプリの絶対パスを指定した`getApp`が`timeoutReached -10005`となり、設定画面へ到達できなかった。GUIを別方式で操作する回避は行っていない。

統括からの追加確認（2026年10月7日）でも、絶対パスの`getApp`は同じtimeoutとなった。inventoryにAppAlignはなく、Finderの観測済みAX actionでDebugのAppAlign.appを開いてから`getApp("AppAlign")`を試しても未到達だった。shell・AppleScript・OrcaによるGUI迂回は行っていない。

後続の受け入れではDebugビルドを`APPALIGN_STORAGE_DIRECTORY`で一時Storeへ向け、空のテスト用ウィンドウを使用する。各アプリで未配置/配置済み、番号順/位置mode、4方向、循環ON/OFF、複数snap→元矩形Restoreを確認する。設定画面前面、dialog、最小サイズ制約、権限撤回、対象終了も確認し、要求矩形と実矩形を分けて記録する。

設定の正常表示・重複binding/登録失敗表示・配置結果を撮影し、画像を目視確認してPRへ添付する。取得できない証拠は未検証として統括の受け入れ判断へ残す。

## 第三者ソース

位置候補の評価式はPowerToys固定コミット`1400fd8e999f381329e16e9df4084f7dc588c8a7`のFancyZones `util.cpp`から翻案した。出典とMicrosoftの著作権・MIT表示を`ZoneNavigator.swift`に保持する。#13のPR #15/#16にある帰属方針・互換性計画の重複文書は作らない。
