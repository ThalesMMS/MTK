import VolumeRenderingCore

extension VolumeTextureFactory {
    convenience init(bodyPart: VolumeCubeMaterial.BodyPart) {
        self.init(preset: bodyPart.datasetPreset)
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
    convenience init(part: VolumeCubeMaterial.BodyPart) {
        self.init(bodyPart: part)
    }
}
