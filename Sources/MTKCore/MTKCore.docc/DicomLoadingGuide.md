# Supplying Decoded DICOM Volumes

MTKCore does not parse DICOM and does not depend on DICOM-Swift.

`DicomCore` exposes `DicomDecodedSeries` as its decoded-series output. MTKCore
accepts `VolumeDataset` as its volume input. The repository deliberately ships
no adapter between those interfaces.

A downstream integration is responsible for:

- validating dimensions, scalar type, slice ordering, and geometry;
- selecting signed or unsigned voxel storage;
- applying or preserving modality rescale metadata;
- mapping spacing, orientation, origin, and series provenance;
- constructing a `VolumeDataset` and handling conversion errors.

After construction, pass the dataset to an MTKCore renderer or volume pipeline.
The result remains a GPU-resident texture frame until the caller explicitly
requests snapshot/export readback.
