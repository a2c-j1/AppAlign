# Issue #9 validation record

Validation records below distinguish automated evidence from checks that require a physical second display. This document contains no machine serials or personal screenshots.

Final local validation: 2026-10-14. Result bundle: `build/issue-3-evidence/AppAlignTests-20261014T054204Z-14379.xcresult` (182 passed, 0 failed, 0 skipped). The parent independently inspected this result and confirmed all 159 baseline test methods and their assertion counts were preserved. No test/smoke AppAlign process belonging to this worktree remained after validation.

## Automated validation

| Area | Evidence | Result |
|---|---|---|
| Placement ticket race, limits, stale revisions and finish cleanup | `PlacementValidityTests` plus keyboard/drag lifecycle barrier tests | PASS: covered by full suite |
| Display callbacks and A→B→A | `DisplayConfigurationControllerTests`: registered userdata through the CoreGraphics callback entry, AppKit/Workspace notification centers, begin/poll/complete, both sleep/display delivery orders, stale epoch and Cancel Quit | PASS: covered by full suite |
| Keyboard post-await ownership | `RuntimeWindowOwnershipTests`: actual `withCurrentFocusedWindow` path with discard, shutdown and focused-target replacement during the preflight barrier | PASS: 11 tests in full suite |
| Keyboard across displays and Restore | `KeyboardLifecycleTests.testKeyboardNavigationCrossesDisplayAndRestoreUsesExactOriginalFrame` | PASS: covered by full suite |
| Manual placement and Restore acceptance | `KeyboardSnapControllerTests.testManualPlacementAndRestoreRejectInvalidationAfterReadback` | PASS: valid control succeeds; invalidated readback cannot publish success and preserves Restore target |
| Navigation direction, repeated local zone numbers, cycle, empty displays | `MultiDisplayTests` | PASS: covered by full suite |
| Drag cursor boundaries, gaps, Dock and Overlay reuse | `DragSnapTests` | PASS: covered by full suite |
| Full macOS build, XCTest and app bundle smoke checks | `./scripts/test.sh` on macOS 27.0.1 / Xcode 26.5 | PASS: 182 tests, 0 failures, 0 skipped; app bundle checks passed |
| Formatting and lint | `swiftformat AppAlign AppAlignTests --lint --config .swiftformat`; `swiftlint lint --no-cache --config .swiftlint.yml` | PASS: 0 files need formatting; 0 violations / 0 serious |
| Semgrep | `.semgrep.yml`, all source files including untracked files | PASS: Semgrep 1.180.0, 4 rules, 38 source files, 0 findings, 0 errors |
| Patch whitespace and project plist | `git diff --check`; `plutil -lint AppAlign.xcodeproj/project.pbxproj` | PASS |
| Existing test preservation | Parent's baseline audit: all 159 existing test method names remain; no existing method has fewer `XCTAssert`, `XCTFail` or `XCTUnwrap` calls | Confirmed by audit and 182-test full suite |

## Physical display and GUI matrix

The available machine is the required MacBook Air M1, running macOS 27.0.1 (build 26A434) with Xcode 26.5 (build 17F42). On 2026-10-09, CUA observed the built-in 1440×900 display only; it did not show a Dell display connected. The parent confirmed a temporary AppAlign process existed and terminated it after inspection. Codex UI automation timed out while trying to attach to the built app (`-10005 timeoutReached`); no app window, Accessibility tree, or visual placement was observed. A process launch is not evidence of correct UI behavior. These GUI observations were not rerun on 2026-10-14 and remain unverified.

| Scenario | Status | Required setup and expected result |
|---|---|---|
| Two displays, zone-order mode | BLOCKED | Connect the required Dell display to the MacBook Air M1; a generic second display does not satisfy the physical validation requirement. Move by number and next/previous in both directions. The destination is evaluated on the cursor/focused window's display, and equal local zone numbers on different displays remain distinct. |
| Two displays, position mode | BLOCKED | With the required MacBook Air M1 + Dell setup, arrange displays horizontally and vertically; test all four directions and cycle. Candidate scoring uses global coordinates and skips empty layouts. |
| Drag across display edge and Shift stationary update | BLOCKED | Drag a window across each edge with and without Shift. The old display overlay hides, the destination display overlay appears, and mouse-up uses the final cursor position. |
| Gap, Dock and menu-bar boundaries | BLOCKED | Place a gap between displays and test Dock/menu-bar areas. No zone is offered there and no overlay remains visible. |
| Hot-unplug during drag or placement | BLOCKED | Remove a display while dragging and while keyboard placement is pending. The app remains responsive, stale work is rejected, and no automatic clamp occurs. |
| Reconnect with same persistent display identity and new runtime ID | BLOCKED | Reconnect and verify the saved assignment returns to that display without changing the saved layout. |
| Main display, resolution, rotation and work-area change | BLOCKED | Change each setting and verify the visible layout refreshes before another placement can be accepted. |
| Sleep/wake and Cancel Quit | BLOCKED | Exercise sleep/wake and Cancel Quit with pending drag/keyboard work. Admission stays closed during refresh, then resumes after the latest configuration is published. |
| Restore after display movement or removal | BLOCKED | Move the source display and restore; the original frame translates by display-origin delta only. Disconnect the source and verify Restore remains available and reports failure instead of clamping. |

The required physical validation is a MacBook Air M1 connected to a Dell display, followed by the steps in the matrix. A generic second display is not a substitute for this completion criterion. Automated fixtures cover deterministic geometry and race behavior but do not replace those physical checks. Issue #9 remains open until that evidence is recorded.
