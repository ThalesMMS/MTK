//
//  VolumePixelFormatHashKey.swift
//  MTKCore
//
//  Maps supported signed and unsigned volume pixel formats to compact cache keys.
//
//  Thales Matheus Mendonça Santos — May 2026
//

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
