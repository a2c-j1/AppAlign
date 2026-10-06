# AppAlign

AppAlign is a native macOS window manager inspired by Microsoft PowerToys FancyZones. It will let people define screen zones and place windows into them with predictable keyboard and drag interactions.

## Project status

This repository contains the initial project scaffold. The first milestone is a dependable single-display zone editor and window placement flow. Multi-display layouts, import/export, and advanced automation can follow once the core interaction is proven.

## Product principles

- Native macOS experience, built with Swift and SwiftUI.
- Make the layout visible and understandable before changing a window.
- Keep window management local; request Accessibility access only when the user enables placement.
- Start with explicit user actions and reversible placement. Avoid background behavior that surprises people.

## Planned first milestone

1. Show connected displays and an editable zone layout.
2. Provide a small set of useful templates and a custom split editor.
3. Let users assign a keyboard shortcut and move the focused window into a zone.
4. Persist layouts per display and restore them on launch.
5. Explain and verify the macOS Accessibility permission flow.

## Development

Requirements: macOS 15 or later, Xcode 26 or later.

Open `AppAlign.xcodeproj` in Xcode, select the `AppAlign` scheme, and run. The project uses SwiftUI and has no third-party package dependencies.

Layouts, display assignments, and settings are stored as separate versioned JSON files under `~/Library/Application Support/jp.a2c.AppAlign/`. Assignments contain persistent display UUIDs and the common Space scope; session-only display identities stay in memory. Invalid or unsupported saved files are copied to uniquely named backups before defaults replace them. If backup or recovery fails, AppAlign protects the original file and reports the save error. On normal quit, pending saves finish before the app exits. A forced process kill can interrupt a write.

Custom layouts may include an optional display name in the existing layout schema. Older AppAlign versions can read files containing this extra field, but if an older version saves the layout again it will omit the name.

## Edit layouts

Open **Display layout → Edit Layout…**, choose a display, then select a saved layout or a template. **Save** stores the definition without changing what the display currently uses; **Apply** assigns the saved definition to that display. **Cancel** discards the current draft. Changing displays, layouts, or templates with unsaved changes prompts to save or discard the draft, or keep editing. Duplicate makes a separately editable copy. The default layout cannot be renamed or deleted; deleting a custom layout clears its display assignments and returns those displays to the default. Use **Reset to Template** to replace a grid with a chosen zone count; this edit can be undone.

Grid ratios are positive integer values that sum to 10000 (for example `2500, 5000, 2500`). Drag a grid boundary to adjust two adjacent ratios. Merge only accepts a rectangular union. Canvas layouts support overlapping rectangles, dragging, resizing, and selecting a covered zone from the zone list.

```sh
xcodebuild -project AppAlign.xcodeproj -scheme AppAlign -destination 'platform=macOS' build
```

## Branching and releases

This repository uses a lightweight Git Flow:

- `main` contains release-ready code. Create version tags from `main` (for example, `v0.1.0`).
- `develop` is the shared integration branch for the next release.
- Create `feature/<short-name>` from `develop`, then merge it back into `develop` through a pull request.
- Create `release/<version>` from `develop` when preparing a release. Stabilize it there, then merge it into both `main` and `develop` and tag the `main` merge.
- Create `hotfix/<short-name>` from `main` for urgent production fixes, then merge the fix into both `main` and `develop`.

Use pull requests for shared branches (`develop` and `main`); do not push feature work directly to them. Branch names use lowercase kebab-case. Commit subjects describe the intent of the change.

## Repository layout

- `AppAlign/` — application source and assets
- `AppAlign.xcodeproj/` — Xcode project
- `docs/` — product and technical notes

## License

All rights reserved. Licensing will be decided before public distribution.

## Automation

The repository keeps build tasks in `scripts/` and calls them from Codex environment setup and GitHub Actions:

- `scripts/setup.sh` checks macOS/Xcode and resolves Swift packages.
- `scripts/build.sh` builds the app into `build/DerivedData`.
- `scripts/test.sh` runs the unhosted `AppAlignTests` XCTest suite, stores its result bundle under `build/issue-3-evidence/`, and checks the built app bundle and executable.
- `scripts/release.sh [version]` archives an unsigned macOS app and creates a ZIP plus SHA-256 file under `build/release`.
- `scripts/cleanup.sh` removes generated files under `build/`.

Pushes and pull requests to `main` or `develop` run the smoke checks. Pushing a `v*` tag creates a GitHub release with the ZIP and checksum.
