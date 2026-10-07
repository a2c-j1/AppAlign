# Issue #8 validation record

## Automated checks

- `scripts/build.sh`: passed on 2026-10-08. `AppAlign.app` executable and bundle identifier smoke checks passed.
- `scripts/test.sh`: passed on 2026-10-08. 150 tests passed, 0 failures. The 134 pre-existing tests remain; added fake-backend regressions cover stationary Shift placement, activation truth table and button masks, strict zone selection, delayed/cancelled handoff and old-session cleanup, same nonfocused AX token commit, keyboard original-frame Restore after drag, A→B→A display generation, settings save/retry races, and overlay panel reuse/cancellation.
- `swiftformat --lint AppAlign --config .swiftformat`: passed, 0/34 files require formatting.
- `swiftlint lint --config .swiftlint.yml --no-cache`: passed, 0 violations across 49 files (including tests).
- `semgrep scan --config .semgrep.yml --error --metrics=off --disable-version-check AppAlign`: passed, 4 rules, 34 files scanned, 0 findings.
- `git diff --check`: passed.

## UI and native Accessibility validation

Unverified. On **2026-10-08 (JST)**, the root reviewer in the Issue #8 chat attempted `cua.getApp` through `cua_repl` using the final build path:

`/Users/a2c/.codex/worktrees/8361/AppAlign/build/DerivedData/Build/Products/Debug/AppAlign.app`

This attempt followed the final 150-test successful build and the source review. The server returned **`Computer Use server error -10005: timeoutReached`** before any initial UI state or screenshot could be obtained. The source was the reviewed, uncommitted Issue #8 change on base `e141a40b8be14c10d2c996c8a81a8911a8d7f963`; only this record was edited afterward. The running GUI process's build identity could not be established. No screenshot or native behavior is claimed for the final commit.

An earlier attempt by this same Issue #8 root reviewer on 2026-10-07 targeted the first successful Issue #8 working-tree build, before later source fixes. It is not evidence for the final revision. Issue #7 GUI results are not reused.

No new TCC grant or input injection was performed. The input monitor remains listen-only and returns the original events. Fake-backend tests do not establish native AX delivery, actual panel focus/click-through behavior, or placement in real applications; these remain for explicit native acceptance. Existing permission and Retry flows remain available.

## Deadline semantics

The write must begin within 2 seconds, and the 5-second total deadline is the boundary for starting new AX reads/writes/retries and requesting resource cleanup. An AX call already in progress may finish late if the operating system does not honor its messaging timeout promptly; the implementation does not claim rollback or no-change once a write has begun. The in-flight slot remains occupied until the runtime task drains.


## Evidence and implementation review

- Environment: macOS 27.0.1, arm64 MacBook Air, Xcode 26.5.
- XCTest result: `build/issue-3-evidence/AppAlignTests-20261007T161131Z-85576.xcresult`. Root read its summary: 150 passed, 0 failed, 0 skipped. Source test-name comparison: all 134 existing tests retained, 16 added.
- Quality tools: SwiftFormat 0.63.1 and SwiftLint 0.65.1, official release asset digests verified; Semgrep 1.179.0. Tools were prepared under `/tmp/appalign-issue8-quality`, with no global installation or rule changes.
- Numbering uses existing `ZoneID.displayNumber`, matching the keyboard UI and layout preview even for sparse IDs. History checked: `cbe96bc6` (#3) and `54608190` (#6). It is not renumbered by layout-array order.
- Root implementation review: **95/100**, requirements 39/40, safety 24/25, validation 23/25, handoff 9/10; acceptance threshold 90, **0 outstanding major defects**. Review confirmed detach-before-release handoff, atomic ownership exchange, cancellation/write ticket, gate OR, native same-target path, monotonic mutations for all applied-layout dictionaries, saved-setting retry merges, and retained keyboard original-frame ownership.
- Implementation is locally accepted; native/UI acceptance remains unverified as described above. No push, PR creation, merge, Issue close, archive, or worktree removal was performed.
