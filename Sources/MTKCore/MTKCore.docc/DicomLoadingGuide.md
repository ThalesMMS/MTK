# DICOM Integration Boundary

MTKCore does not parse DICOM sources. DICOM file discovery, ZIP extraction,
path-traversal validation, slice ordering, geometry validation, rescale
slope/intercept, window metadata, and DICOM-specific errors belong to the
`DICOM-Swift` package.

MTKCore consumes renderer-ready `VolumeDataset` values. Apps that want the
default DICOM-Swift integration should import `MTKDicomBridge`, which converts
`DicomCore.DicomDecodedSeries` into `VolumeDataset` without redefining DICOM
protocols inside MTKCore.

```swift
import MTKCore
import MTKDicomBridge

let importer = DicomVolumeDatasetImporter()
importer.loadDataset(from: sourceURL, progress: { update in
    switch update {
    case .started(let totalSlices):
        print("Loading \(totalSlices) slices")
    case .reading(let fraction, _):
        print("Progress \(fraction)")
    }
}, completion: { result in
    switch result {
    case .success(let importResult):
        let dataset = importResult.dataset
        // Apply the dataset to MTKUI or a rendering adapter.
        _ = dataset
    case .failure(let error):
        // DICOM errors are surfaced from DicomCore.
        print(error.localizedDescription)
    }
})
```

Use `DicomCore.DicomSeriesLoader` directly when an app needs access to raw and
modality-converted DICOM buffers. Use `MTKDicomBridge` only when the next step is
rendering through MTK.
