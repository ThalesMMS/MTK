extension VolumePixelFormat {
    var hashKey: Int {
        switch self {
        case .int16Signed:
            return 0
        case .int16Unsigned:
            return 1
        }
    }
}
