# Viewer Platform Adaptation

How MTKUI viewer components adapt to iPhone, iPadOS, and macOS, and which
component to use where.

## Overview

MTKUI separates **low-level surfaces** (Metal-backed viewports you can embed
anywhere) from **viewer chrome** (complete shells with headers, docks,
toolbars, and inspectors). Layout decisions flow through one abstraction —
``ViewerLayoutClass`` — resolved by ``ViewerLayoutClassResolver`` from window
size, size classes, and desktop idioms, or injected explicitly with
`viewerLayoutClass(_:)` for previews, tests, and custom shells.

## Layout classes

| Class | Typical windows | Chrome behavior |
| --- | --- | --- |
| `compactPhone` | iPhone portrait, narrow iPad split panes (compact width, regular height) | Stacked compact chrome; single viewport focus; bottom dock |
| `compactTablet` | iPhone landscape (compact height), regular-width windows below 700pt (split view, Stage Manager) | Full grid; bottom dock fallback |
| `tablet` | iPad regular-width windows ≥ 700pt | Full grid; trailing side dock (320pt) |
| `desktop` | macOS windows (always) | Toolbar + trailing inspector (300pt); pointer/keyboard first |

Breakpoints: 500pt (phone) and 700pt (tablet), mirroring the demo shell.

## Platform support matrix

| Component | Kind | iPhone | iPadOS | macOS |
| --- | --- | --- | --- | --- |
| ``MetalViewportView`` / ``MetalViewportContainer`` | Low-level surface | ✓ | ✓ | ✓ |
| ``ClinicalViewerSurface`` | Mode-dispatching surface | ✓ | ✓ | ✓ |
| ``ClinicalViewportGrid`` | MPR grid (3 panes + fullscreen slot) | ✓ compact chrome | ✓ | ✓ |
| ``ClinicalViewerTabletChrome`` | Complete chrome (header + adaptive dock) | ✓ bottom dock | ✓ side/bottom dock | usable, prefer desktop chrome |
| ``ClinicalViewerDesktopChrome`` | Complete chrome (toolbar + inspector) | — touch-first apps should prefer tablet chrome | ✓ with pointer/keyboard | ✓ |
| ``ViewerDesktopToolbar`` / ``ViewerInspectorPanel`` | Chrome building blocks | ✓ | ✓ | ✓ |
| ``ViewerCommandDescriptor`` + `viewerKeyboardCommands(_:onCommand:)` | Commands/shortcuts | hardware keyboards only | ✓ | ✓ |
| `viewerPaneContextMenu(_:onCommand:)` | Context menus | long-press | long-press / right-click | right-click |
| ``ViewerScrollSliceAccumulator`` / ``ViewerScrollZoomNormalizer`` | Scroll normalization | n/a (touch) | pointer/trackpad | ✓ |
| `MPRScreenLayout.primaryLeft` / `.vSplit1x3` | Large-screen MPR presets | not recommended | `.primaryLeft` | both |

What belongs in MTKUI versus your app: MTKUI owns surfaces, grids, chrome
structure, layout resolution, command models, and interaction primitives.
Your app owns the shell (windows, scenes, navigation), the dock/inspector
*content* (which tools and presets to show), command handling, and DICOM
loading.

## Minimal integrations

### iPhone (compact)

The grid resolves `compactPhone` automatically and uses its stacked compact
chrome — no extra shell needed:

```swift
ClinicalViewportGrid(session: session)
```

### iPadOS (tablet chrome)

```swift
ClinicalViewerTabletChrome(
    title: study.displayName,
    mode: coordinator.mode,
    onSelectMode: { coordinator.mode = $0 },
    content: { ClinicalViewerSurface(coordinator: coordinator) },
    dock: { MyViewerControls(coordinator: coordinator) }
)
.viewerKeyboardCommands { coordinator.handle($0) }
```

The dock presents as a trailing side panel on `tablet` windows and falls
back to a height-capped bottom dock on narrow split-view windows.

### macOS (desktop chrome)

```swift
ClinicalViewerDesktopChrome(
    mode: coordinator.mode,
    onCommand: { coordinator.handle($0) },
    content: { ClinicalViewerSurface(coordinator: coordinator) },
    inspector: {
        ViewerInspectorSection("Window/Level") { MyWWLControls() }
        ViewerInspectorSection("MPR Layout") { MyLayoutPicker() }
        ViewerInspectorSection("Export") { MyExportControls() }
    }
)

// Mirror the same commands in the menu bar:
CommandMenu("Viewer") {
    ForEach(ViewerCommandDescriptor.defaultViewerCommands) { command in
        Button(command.title) { coordinator.handle(command.id) }
            .keyboardShortcut(command.keyboardShortcut)
    }
}
```

Surface large-screen MPR presets only where they fit:

```swift
let layouts = MPRScreenLayout.recommendedLayouts(for: resolvedClass)
factory.configuration(for: .clinical, availableMPRScreenLayouts: layouts, ...)
```

## Migrating from MTK-Demo shell copies

Code that copied the demo shell's width breakpoints, split layout, compact
shell, or control dock should move to the reusable components:

1. Replace hand-rolled breakpoint checks with ``ViewerLayoutClassResolver``
   (the 700pt/980pt demo breakpoints map to the `tablet` boundary and the
   side-dock presentation).
2. Replace the demo's split dock layout with ``ClinicalViewerTabletChrome``
   (iPad) or ``ClinicalViewerDesktopChrome`` (macOS), supplying your
   controls as the dock/inspector content.
3. Replace ad-hoc keyboard/menu handling with ``ViewerCommandDescriptor``
   bridging (`viewerKeyboardCommands`, `.commands` menus,
   `viewerPaneContextMenu`).
4. Keep demo-only styling (e.g. iOS 18 glass effects) in your app; the
   MTKUI chrome uses portable materials.

## Known limitations and follow-ups

- The MPR grid model has three content panes plus a fullscreen slot; quad
  (2×2 with optional 3D) layouts require a fourth slot and are a follow-up.
- ``ViewerInteractionCapabilities`` defaults are conservative on iPadOS
  (`touchOnly`); hosts that detect a trackpad/keyboard should inject
  `tabletWithPointer` themselves.
- Scroll normalization is exposed as pure logic
  (``ViewerScrollSliceAccumulator``); wiring it into every viewport's
  event stream is incremental.
- Stage Manager/external-display behavior is derived from window geometry;
  no scene-level integration is provided.
- The clinical rendering backend, DICOM loading, and decoding contracts
  are unchanged by the adaptation layer, and none of this implies
  diagnostic-device validation.

## Topics

- ``ViewerLayoutClass``
- ``ViewerLayoutClassResolver``
- ``ClinicalViewerTabletChrome``
- ``ClinicalViewerDesktopChrome``
- ``ViewerCommandDescriptor``
- ``ViewerInteractionCapabilities``
