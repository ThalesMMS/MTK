#if !os(iOS)
public enum NativeVolume3DInteractionMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case orbit
    case pan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orbit:
            return "Orbit"
        case .pan:
            return "Pan"
        }
    }
}
#endif
