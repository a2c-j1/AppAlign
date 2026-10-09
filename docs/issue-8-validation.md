# Issue #8 validation record

## Automated checks

- `scripts/build.sh`: passed on 2026-10-08. `AppAlign.app` executable and bundle identifier smoke checks passed.
- `scripts/test.sh`: passed on 2026-10-08. 159 tests passed, 0 failures. The 134 pre-existing tests remain; 25 Issue #8 regressions cover activation truth table and button masks, strict zone selection, delayed/cancelled handoff and old-session cleanup, same nonfocused AX token commit, keyboard original-frame Restore after drag, A→B→A display generation, settings save/retry races, overlay panel reuse/cancellation, final-release zone selection, and detector-driven Escape/stop/quit cancellation while moving or while commit is pending.
- `swiftformat --lint AppAlign --config .swiftformat`: passed, 0/34 files require formatting.
- `swiftlint lint --config .swiftlint.yml --no-cache`: passed, 0 violations across 50 files (including tests).
- `semgrep scan --config .semgrep.yml --error --metrics=off --disable-version-check AppAlign`: passed, 4 rules, 34 files scanned, 0 findings.
- `git diff --check`: passed.

## UI and native Accessibility validation

Unverified. On **2026-10-08 (JST)**, the root reviewer in the Issue #8 chat attempted `cua.getApp` through `cua_repl` using the 150-test implementation build path:

`/Users/a2c/.codex/worktrees/8361/AppAlign/build/DerivedData/Build/Products/Debug/AppAlign.app`

This attempt followed the 150-test successful implementation build and source review. The server returned **`Computer Use server error -10005: timeoutReached`** before any initial UI state or screenshot could be obtained. The source was the reviewed, uncommitted Issue #8 change on base `e141a40b8be14c10d2c996c8a81a8911a8d7f963`; it was then committed as `5998fc8f41cfdfdfaac4fa84d55ce3eb92de9f6f`. The subsequent 159-test revision adds acceptance tests, shared fake visibility, project registration and validation documentation; it makes no production-source changes. No new GUI attempt was made for the 159-test revision. The running GUI process's build identity could not be established. No screenshot or native behavior is claimed for the final commit.

An earlier attempt by this same Issue #8 root reviewer on 2026-10-07 targeted the first successful Issue #8 working-tree build, before later source fixes. It is not evidence for the final revision. Issue #7 GUI results are not reused.

No new TCC grant or input injection was performed. The input monitor remains listen-only and returns the original events. Fake-backend tests do not establish native AX delivery, actual panel focus/click-through behavior, or placement in real applications; these remain for explicit native acceptance. Existing permission and Retry flows remain available.

## Deadline semantics

The write must begin within 2 seconds, and the 5-second total deadline is the boundary for starting new AX reads/writes/retries and requesting resource cleanup. An AX call already in progress may finish late if the operating system does not honor its messaging timeout promptly; the implementation does not claim rollback or no-change once a write has begun. The in-flight slot remains occupied until the runtime task drains.


## Evidence and implementation review

- Environment: macOS 27.0.1, arm64 MacBook Air, Xcode 26.5.
- Latest XCTest result: `build/issue-3-evidence/AppAlignTests-20261008T135506Z-64716.xcresult`; 159 passed, 0 failed, 0 skipped. Source test-name comparison: all 134 existing tests retained; 25 Issue #8 tests are now added.
- New release/cancellation acceptance tests are in `AppAlignTests/DragDetectorSnapAcceptanceTests.swift`. The three final-release cases and all six Escape/stop/quit × moving/commit-pending cases passed individually in the latest XCTest result. Each cancellation case uses the detector callback chain, waits for both drag leases and commit owners to drain, and asserts zero writes and hidden overlays. Pending cases block the fake commit, release through the detector, wait for the commit barrier, cancel via the detector, resume the backend, and then assert drain.
- Quality tools: SwiftFormat 0.63.1 and SwiftLint 0.65.1, official release asset digests verified; Semgrep 1.179.0. Tools were prepared under `/tmp/appalign-issue8-quality`, with no global installation or rule changes.
- Numbering uses existing `ZoneID.displayNumber`, matching the keyboard UI and layout preview even for sparse IDs. History checked: `cbe96bc6` (#3) and `54608190` (#6). It is not renumbered by layout-array order.
- Supervisor review of the 150-test revision: **88/100, HOLD**, superseding the earlier root 95/100 acceptance. It identified missing final-release and detector-driven cancellation evidence.
- Root independent re-review of the 159-test revision: **96/100** (requirements 39/40, safety 24/25, validation 24/25, handoff 9/10), threshold 90, **0 outstanding major findings**. Root reviewed the actual detector callback wiring and frame-following fixture, read all nine individual Passed results and the 159/0/0 XCTest summary, verified retention of all 134 original tests, and independently reran all three quality tools. The implementation is LOCAL_READY. Native/UI acceptance remains unverified.
- Supervisor independent re-review: **94/100** (requirements 38/40, safety 24/25, validation 23/25, handoff 9/10), **0 major findings**. The supervisor independently reviewed the nine tests and copied/read the latest XCTest result, lifted HOLD, and accepted the local implementation. Native/GUI validation remains tracked for Issue #13; Issue #8 is not marked complete.
- No push, PR creation, merge, Issue close, archive, or worktree removal was performed.
