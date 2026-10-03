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
