import MTKCore

extension VolumeTextureFactory {
    /// Creates a factory for the specified body part.
    ///
    /// Unlike `init(preset:)`, this initializer treats `.none` and `.dicom` as requests
    /// for a minimal placeholder dataset suitable for initialization before real data loads.
    ///
    /// - Parameter bodyPart: The body part preset to load.
    /// - Throws: ``PresetLoadingError`` when `.chest` or `.head` resources are unavailable.
    convenience init(bodyPart: VolumeCubeMaterial.BodyPart) throws {
        switch bodyPart {
        case .none, .dicom:
            self.init(dataset: Self.debugPlaceholderDataset())
        case .chest, .head:
            try self.init(preset: bodyPart.datasetPreset)
        }
    }
}

extension VolumeCubeMaterial.BodyPart {
    var datasetPreset: VolumeDatasetPreset {
        switch self {
        case .none:
            return .none
        case .chest:
            return .chest
        case .head:
            return .head
        case .dicom:
            return .dicom
        }
    }
}

extension VolumeTextureFactory {
    // Backward compatibility for existing call sites expecting the old label.
    convenience init(part: VolumeCubeMaterial.BodyPart) throws {
        try self.init(bodyPart: part)
    }
}
