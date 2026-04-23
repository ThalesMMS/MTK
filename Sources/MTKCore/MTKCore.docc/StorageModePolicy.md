# Storage Mode Policy

MTKCore keeps the interactive rendering path GPU-native. CPU-visible resources are used only at ingestion, UI-authored lookup tables, and explicit readback boundaries.

## Resource Types

- Volume 3D textures: use `.private` for async and chunked upload paths. They are final rendering resources and are not read directly by the CPU.
- CPU reference volume textures: may use `.shared` only in the synchronous `VolumeTextureFactory.generate(device:)` path used by tests and small debug uploads.
- Staging buffers: use `.storageModeShared` with `.cpuCacheModeWriteCombined` for one-way CPU writes before a blit or compute upload.
- Transfer function textures: use `.shared` because they are small CPU-authored lookup tables updated from UI state.
- Output render targets: use `.private`; render passes write them on the GPU and presentation samples or copies them without CPU access.
- Readback resources: use `.shared`, or `.managed` on discrete macOS GPUs, only for snapshot/export/debug/tests.
- Argument, uniform, histogram, statistics, and other compute scratch buffers: use `.shared` when the CPU writes inputs, reads results, or updates small per-dispatch data.
- Acceleration and MPR intermediate textures: set storage explicitly at allocation; use `.private` for GPU-only intermediates and `.shared` only when CPU access is required.
- Capability probe textures: set storage explicitly to match the resource behavior being probed.

## Migration Notes

- New volume upload code should prefer `ChunkedVolumeUploader` when raw slices are available and should not allocate a full-volume staging buffer.
- New rendering targets should set `.private` explicitly instead of relying on Metal defaults.
- New CPU readback code should allocate a separate readback buffer or texture and keep it out of the interactive frame loop.
- Existing `.shared` volume textures are retained only for CPU reference helpers used by tests and debug tooling.
