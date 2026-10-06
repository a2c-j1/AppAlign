# Issue #5 validation

## Automated coverage

| Review concern | Regression coverage |
| --- | --- |
| Split only the selected Grid zone; preserve other merged cells and sparse IDs; reject overflow and the 128-zone limit | `LayoutEditorTests.testSelectedGridZoneSplitPreservesOtherMergedZonesAndRatios`, `testRowSplitChangesOnlySelectedZone`, `testSplitMergedZonesUsesRectangularCutAndLeavesOtherZoneIDsUntouched`, `testGridSplitHonorsZoneLimitAt127And128Zones`, `testSparseZoneIDsAndOverflowAreHandled` |
| Reject non-rectangular merges and invalid ratios/spacing without changing the draft or history | `LayoutEditorTests.testRectangleMergePreservesTopLeftZoneIDAndRejectsLShape`, `testRejectedGridEditRestoresDraftSelectionAndHistory` |
| Preserve Canvas IDs while allowing overlap, move, and resize | `LayoutEditorTests.testCanvasOverlapMoveResizeAndStableIDs`; `LayoutEditorConcurrencyTests.testAcceptanceLayoutsSaveReloadAndCancelWithoutChangingAppliedDefinition` |
| Save and Apply remain separate; Cancel leaves saved bytes and applied zones unchanged | `LayoutEditorConcurrencyTests.testSaveFailureKeepsDraftUndoAndCancelLeavesStoreAndAppliedZonesUnchanged`, `testAcceptanceLayoutsSaveReloadAndCancelWithoutChangingAppliedDefinition` |
| Keep authoritative disk/runtime state through FIFO, retry, stale completion, copy-on-write, and partial delete failures | `LayoutEditorConcurrencyTests` covers queued Apply/Save, superseded operations, queued delete, default assignment, old retry isolation, and second-file delete failure |
| Preserve names in schema 1 and decode older layouts without a name | `LayoutEditorTests.testGridPercentagesPersistAndLegacyMissingNameDecodes` |
| Undo/Redo, one history item per gesture, and Escape cancellation | `LayoutEditorTests.testEditorModelUndoRedoGestureAndCancelPreserveBaseline`, `testCancelGestureRestoresDraftSelectionAndSignalsPreviewWithoutAddingHistory` |

Final verification on 2026-10-06 passed all 58 XCTest cases (the existing 36 plus 22 editor regressions), with zero failures and zero skipped tests. `scripts/test.sh` completed the macOS build and bundle smoke checks. The result bundle is `build/issue-3-evidence/AppAlignTests-20261006T120549Z-60371.xcresult`; the execution log is `/private/tmp/issue5-submission-test.log`. Environment: Xcode 26.5, macOS 27.0.1, arm64.

SwiftFormat checked all 20 Swift files with zero changes required. SwiftLint checked those 20 files with zero violations. Semgrep ran all four architectural rules on all 16 staged application Swift sources with zero findings. Each command exited 0, and the staged diff passed `git diff --cached --check`.

A newer successful editor save invalidates an older failed legacy save's captured retry operation, preventing that old snapshot from overwriting a newer catalog or another display's assignment. Two-file Apply/delete operations preserve the existing write order and may partially succeed; failure handling reloads the durable state rather than claiming a transaction rollback.

## Manual acceptance

Use a Debug build with an isolated temporary store so the acceptance pass does not modify real user settings:

```sh
issue5_storage="$(mktemp -d /private/tmp/appalign-issue5-acceptance.XXXXXX)"
APPALIGN_STORAGE_DIRECTORY="$issue5_storage" build/DerivedData/Build/Products/Debug/AppAlign.app/Contents/MacOS/AppAlign
```

Open **Settings → Edit Layout…** and inspect these interactions on a connected display:

1. Change Display and verify the editor loads that display's applied definition.
2. Choose Columns, Rows, Grid, PriorityGrid, and Focus templates; confirm each preview follows the real display work area.
3. Enter `2500, 5000, 2500`, apply it, and verify the middle zone is twice the width of each side zone. Drag a boundary, then Undo and Redo.
4. Split a selected zone, merge a rectangular selection, and confirm an L-shaped selection is rejected. Change the zone count with **Reset to Template** and Undo it.
5. Create a Canvas layout, overlap two rectangles, move and resize one, and select the covered rectangle from the zone list.
6. Save a definition and verify the applied checkmark and current display remain unchanged. Apply it and confirm the applied indicator updates.
7. Change a layout and choose Cancel; confirm reopening the editor shows the previous saved definition. Try switching layouts with a dirty draft and test Save, Discard, and Keep Editing.
8. Duplicate and rename a custom layout. Delete it and confirm its display returns to the default; confirm the default cannot be deleted or renamed.
9. During a boundary or Canvas drag, press Escape. Confirm the gesture reverts, the pointer is ignored until mouse-up, and later drags still work.

This manual GUI pass and its screenshot were not performed in the implementation environment.
