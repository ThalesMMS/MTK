#if !os(iOS)
public enum NativeVolume3DInteractionMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case orbit
    case pan
    case transferFunction
    case crop
    case brush

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orbit:
            return "Orbit"
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
#endif
