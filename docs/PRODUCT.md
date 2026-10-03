# Product direction

## Goal

Bring the core FancyZones idea to macOS: define reusable screen regions, then place application windows into those regions quickly and consistently.

## First release boundary

The first release should prove three things: people can understand the zones, create a useful layout without technical knowledge, and place a window without losing control of its size or position. Start with one display at a time and a deliberately small template set. Add multi-display persistence after the placement model is reliable.

## Interaction sketch

1. The menu bar app opens a layout editor for a selected display.
2. The editor presents a live display canvas with visible zones and a template gallery.
3. The user saves a layout and chooses a shortcut.
4. When invoked, AppAlign shows a zone overlay; choosing a zone moves the focused window there.

## macOS constraints to validate

- Window discovery and repositioning depend on macOS Accessibility authorization and can vary by application.
- Spaces, full-screen windows, Stage Manager, display scaling, and menu-bar/dock insets affect coordinate mapping.
- The app should expose permission status, explain the specific capability required, and degrade clearly when a target app cannot be controlled.

## Open product decisions

- Menu bar only, regular app window, or both.
- Keyboard-first placement versus drag-to-zone as the primary interaction.
- Whether layouts should adapt to display resolution or remain normalized proportions.
- Distribution and signing approach.
