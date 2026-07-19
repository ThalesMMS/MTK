# Volume Pipeline

MTKCore's volume pipeline transforms `VolumeDataset` values without owning a
product interface.

```swift
import MTKCore

let result = try VolumePipeline(source: source)
    .applying(filter)
    .map()
```

The source owns acquisition, a filter transforms volume data or metadata, and
the mapper produces renderer-ready values. Downstream applications retain
responsibility for presentation and input handling.

Pipeline output feeds the Metal renderer and ends as `MTLTexture`-backed frame
values. Converting a frame to `CGImage` is an explicit snapshot/export operation,
not part of the interactive pipeline.
