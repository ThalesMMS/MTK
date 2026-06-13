public enum NativeVolume3DInteractionMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case orbit
    case tilt
    case pan
    case transferFunction
    case crop
    case brush

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orbit:
            return "Orbit"
        case .tilt:
            return "Tilt"
        case .pan:
            return "Pan"
        case .transferFunction:
            return "Transfer Function"
        case .crop:
            return "Crop"
        case .brush:
            return "Brush"
        }
    }
}

extension NativeVolume3DInteractionMode {
    var allowsNativeCameraGestures: Bool {
        switch self {
        case .orbit, .tilt, .pan, .transferFunction:
            return true
        case .crop, .brush:
            return false
        }
    }
}
