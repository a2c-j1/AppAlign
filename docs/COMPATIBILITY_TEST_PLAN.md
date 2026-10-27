# Compatibility and endurance validation plan

This document defines the repeatable manual validation required by roadmap issue #13. It is intentionally independent of the implementation branches for window placement, layout calculation, input handling, and Spaces so that every feature PR can reuse the same evidence format as those capabilities arrive.

## Goals

Validation should answer four questions:

1. Does AppAlign preserve window state correctly across supported applications?
2. Does it fail safely when macOS permissions, displays, Spaces, or target applications change?
3. Does repeated use leave input hooks, overlays, observers, or queued work growing without bound?
4. Can a signed build acquire the permissions it needs and still perform the basic placement flow?

A test is not complete merely because AppAlign does not crash. Record the requested action, the observed window frame/state, any recovery action, and whether AppAlign retained stale placement state after a failure.

## Evidence format

For every manual run, record:

- AppAlign revision or PR
- macOS version and build
- Mac model / architecture
- display model, connection type, scaling, rotation, and primary-display status
- target application and version
- relevant AppAlign settings
- Accessibility and Input Monitoring permission state
- expected result
- observed result
- PASS / FAIL / BLOCKED
- logs or screenshots only when they do not expose unnecessary user content

Do not record window titles, document names, URLs, typed text, or other user content unless it is strictly needed to reproduce a defect.

## Application compatibility matrix

Run the applicable placement and recovery cases against at least:

| Application | Normal window | Minimum-size clamp | Dialog / sheet exclusion | Full-screen exclusion | App quit during operation | Restore original frame |
| --- | --- | --- | --- | --- | --- | --- |
| Finder | Pending | Pending | Pending | Pending | Pending | Pending |
| Safari | Pending | Pending | Pending | Pending | Pending | Pending |
| Google Chrome | Pending | Pending | Pending | Pending | Pending | Pending |
| Ghostty | Pending | Pending | Pending | Pending | Pending | Pending |
| Visual Studio Code | Pending | Pending | Pending | Pending | Pending | Pending |

For each application, verify both an ordinary resizable window and at least one edge case that is native to that application. If an application constrains the requested frame, record the requested frame separately from the measured frame and treat the measured result as the source of truth.

## Permission and target-failure cases

These checks should be repeated whenever Accessibility or input-monitoring code changes.

| Case | Expected behavior |
| --- | --- |
| Accessibility permission absent at launch | App remains usable for non-AX features and explains why placement is unavailable. |
| Accessibility request denied | No placement state is committed and no retry loop spins indefinitely. |
| Accessibility permission revoked while running | Active work is cancelled or fails finitely; later UI reflects the missing permission. |
| Permission restored | App can recover without requiring a reboot; document if relaunch is required by macOS. |
| Target window closes before commit | No stale assignment is recorded and the operation returns to idle. |
| Target app quits while AX request is in flight | The request times out/fails finitely and AppAlign remains responsive. |
| Window becomes non-writable | Failure is surfaced without recording a successful placement. |
| AppAlign's own window/settings panel is focused | It is never selected as a placement target. |

## Display and coordinate cases

When display support is available, cover these configurations with the same layout and a known reference window:

- internal display only
- Dell external display only
- internal + Dell side-by-side, with the external display on both the left and right
- external display above and below the internal display
- each display acting as the primary display
- Retina and non-Retina / scaled modes where available
- rotated external display
- menu bar and Dock moved between displays/edges
- disconnect and reconnect while idle
- disconnect during an active drag or placement operation
- sleep/wake with an external display attached
- resolution or scaling change while AppAlign is running

For every configuration, compare the visual work area with the frame AppAlign actually requests. Negative global coordinates and primary-display changes must not cause mirrored or offset placement.

## Mission Control, Spaces, and Stage Manager

When the corresponding features exist in the current build, verify:

- Space switch while idle
- Space switch during an active drag
- entering and leaving full screen
- Mission Control opened during a drag
- Stage Manager enabled and disabled while AppAlign is running
- Stage Manager app group changes while a target window is selected
- display-specific Spaces enabled and disabled
- target Space or display becoming unavailable before commit

Any transition that invalidates a work area or window reference should cancel the active operation before those references are reused.

## Drag and input resilience

When drag snapping is available, verify:

- title-bar drag is detected
- text selection is not detected as window movement
- browser tab drag/reorder is not detected as window movement
- content drag-and-drop is not detected as window movement
- resize gestures are not mistaken for move gestures
- Shift pressed after drag start updates activation without pointer movement
- Shift released before mouse-up updates activation without pointer movement
- Escape cancels without placement
- event-tap disable/re-enable returns the state machine to idle
- mouse-up arriving before delayed AX work does not revive an old drag session
- stale session/generation results are ignored after display or layout changes

## Endurance / soak runs

Use an Activity Monitor sample, Instruments session, or equivalent diagnostic capture when available.

### Repeated placement

Perform at least 500 placement/restore cycles across two applications.

Record before/after:

- resident memory
- thread count
- open file descriptors if relevant
- active AX observers
- event taps
- overlay windows/panels
- pending input or placement queue depth

The run fails if resources grow continuously with the number of operations rather than returning to a stable range.

### Drag churn

Perform at least 250 drag sessions containing a mix of successful drops, cancellations, target-app exits, and display-boundary crossings.

Confirm:

- only the expected reusable overlay instances remain
- cancelled sessions return to idle
- no session identifier can commit twice
- event processing remains responsive near the end of the run

### Display churn

Repeat external-display disconnect/reconnect at least 25 times, including several cycles while a drag is active.

Confirm:

- active operations are invalidated before work-area replacement
- assignments are not silently deleted solely because a display is temporarily absent
- observer/tap counts do not increase per cycle

### Sleep/wake

Run at least 20 sleep/wake cycles with AppAlign left running, including cycles with the external display attached and detached.

Confirm that permissions, observers, display state, and input monitoring recover or fail visibly without busy retry loops.

## Diagnostic logging requirements

Diagnostics should make the endurance cases observable without storing unnecessary user data.

Prefer counters and stable internal identifiers for:

- AX request timeout/failure counts
- active input session/generation
- coalesced or dropped move-event counts
- input queue depth/high-water mark
- active overlay count
- observer creation/destruction count
- event-tap recreation count
- work-area generation changes
- placement requested/measured frame mismatch counts

Do not log window titles, document names, typed text, clipboard contents, or arbitrary accessibility attribute dumps.

## Release-candidate gate

Before marking #13 complete, run the full applicable matrix on the target release environment, including the M1 + macOS 26 + Dell combination named in the roadmap issue.

The release-candidate gate requires:

- the supported-app matrix completed with no unexplained placement-state corruption
- permission denial, revocation, and recovery exercised
- Mission Control / Stage Manager / sleep-wake / display disconnect cases exercised where supported
- endurance runs showing bounded resource usage
- a signed/notarized distribution build launched outside Xcode
- permission acquisition and the basic placement/restore flow verified from that distribution build
- any BLOCKED row linked to a concrete issue rather than silently treated as PASS

This document is a living test plan. Feature PRs may add rows as new failure modes are discovered, but should not weaken an existing expectation without explaining why.
