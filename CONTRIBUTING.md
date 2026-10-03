# Contributing

## Getting started

Use Xcode 26 or newer on macOS 15 or newer. Open `AppAlign.xcodeproj` and run the `AppAlign` scheme.

## Engineering direction

- Keep the first version native: SwiftUI for the app and AppKit/CoreGraphics APIs only where window management requires them.
- Separate layout modeling from display discovery, permission state, and window placement so each boundary is easy to reason about.
- Treat Accessibility access as optional until the user starts a feature that needs it. Explain why it is needed at that point.
- Keep changes small and verify a macOS build before proposing a change.

## Pull requests

Describe the user-visible behavior, permission impact, and how the change was checked. Include screenshots for visual changes.
