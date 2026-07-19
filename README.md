# MTK

MTK is now a core-only Swift package for medical volume rendering. It ships:

- `MTKCore` for volume data, Metal rendering, presentation passes, export, and
  MPR/transfer-function primitives.
- `MTKFixtures` for reusable test and rendering fixtures.

## Screenshots

Example integrations using `MTKCore`. The host application UI shown is not
shipped as part of this package.

<p align="center">
  <img src="screenshots/screenshot1.PNG" alt="3D volume rendering with MTKCore" width="45%">
  <img src="screenshots/screenshot2.PNG" alt="Multiplanar reconstruction with MTKCore" width="45%">
</p>

## What is included

- `VolumeDataset` as the stable input contract
- Metal-native rendering, `MTLTexture` frames, `PresentationPass`, and
  `MPRPresentationPass`
- `CGImage` export and snapshot/readback helpers
- Transfer functions, volume pipeline helpers, and clinical geometry/picking
- Loaders and adapters that stay inside the core rendering contract

## What is not included

- No shipped product UI module
- No demo app
- No SwiftUI, UIKit, or AppKit product surface
- No external bridge package

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/ThalesMMS/MTK.git", from: "1.0.0")
]
```

Then depend on:

```swift
.product(name: "MTKCore", package: "MTK")
.product(name: "MTKFixtures", package: "MTK")
```

## Core flow

The package contract ends at frames and textures:

`VolumeDataset` -> loader/transform -> GPU textures -> render passes ->
`PresentationPass` / `MPRPresentationPass` -> `MTLTexture` or explicit
`CGImage` export.

## Testing

```bash
cd MTK && swift build
cd MTK && swift test
cd MTK && swift build -c release
```
