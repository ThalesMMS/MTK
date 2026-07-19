# Multi-Planar Reconstruction

MTKCore provides GPU-native MPR geometry, reslicing, frame generation, and
drawable presentation passes without hosting a product interface.

## Data flow

1. Construct a `VolumeDataset` with dimensions, spacing, orientation, and
   origin.
2. Upload and retain the volume through MTKCore resource management.
3. Define axial, coronal, sagittal, or oblique plane geometry.
4. Encode the MPR reslice pass.
5. Consume the resulting `MPRTextureFrame` as an `MTLTexture`.
6. Optionally encode `MPRPresentationPass` into a caller-supplied
   `CAMetalDrawable`.

Crosshair state, synchronized layouts, gestures, annotations, and platform view
lifecycle belong to the downstream application. Snapshot/export readback remains
explicit through the supported exporter interfaces.
