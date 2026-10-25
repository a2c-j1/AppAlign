# Contributing

## Getting started

Use Xcode 26 or newer on macOS 15 or newer. Open `AppAlign.xcodeproj` and run the `AppAlign` scheme.

## Engineering direction

- Keep the first version native: SwiftUI for the app and AppKit/CoreGraphics APIs only where window management requires them.
- Separate layout modeling from display discovery, permission state, and window placement so each boundary is easy to reason about.
- Treat Accessibility access as optional until the user starts a feature that needs it. Explain why it is needed at that point.
- Keep changes small and verify a macOS build before proposing a change.

## Quality checks

Install the local quality tools with Homebrew:

```sh
brew install swiftformat swiftlint semgrep
```

Run the same checks used by pull requests. XCTest sources are included in both SwiftFormat and SwiftLint:

```sh
swiftformat AppAlign AppAlignTests --lint --config .swiftformat
swiftlint lint --config .swiftlint.yml
semgrep scan --config .semgrep.yml --error AppAlign
scripts/test.sh
```

SwiftFormat intentionally starts with whitespace-only rules. SwiftLint is strict. Semgrep carries AppAlign-specific architectural boundaries for Accessibility, event taps, and private Space APIs.

## Pull requests

Describe the user-visible behavior, permission impact, and how the change was checked. Include screenshots for visual changes.

Target pull requests as follows:

- `feature/*` and `bugfix/*` → `develop`
- `release/*` → `main` and `develop` (complete both merges for the release)
- `hotfix/*` → `main` and `develop` (complete both merges)

Use lowercase kebab-case branch names. Keep `main` release-ready and use `develop` for integration. Tag releases on `main` with a `v` prefix, such as `v0.1.0`.

## Starting work

```sh
git switch develop
git pull --ff-only
git switch -c feature/short-name
```

Before opening a pull request, build the app with the command in the README and describe the result in the pull request.
