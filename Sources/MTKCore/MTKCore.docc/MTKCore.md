# ``MTKCore``

Core Metal rendering, volume data, and export primitives for medical imaging.

`MTKCore` is the rendering side of the repository. It accepts
``VolumeDataset`` input, produces `MTLTexture` frames through Metal passes, and
exposes explicit snapshot/export boundaries through ``SnapshotExporting`` and
``TextureSnapshotExporter``. Interactive presentation ends at drawables or
textures; the package does not host product UI.

The main stable contract is:

- ``VolumeDataset`` and the supporting volume metadata types
- transfer functions and window/level primitives
- rendering passes such as ``PresentationPass`` and
  ``MPRPresentationPass``
- explicit export and readback helpers

For downstream application integration, keep the UI layer outside the package.
If an app needs to create a viewer, it should do so as a separate integration
layer that consumes the public core APIs.
