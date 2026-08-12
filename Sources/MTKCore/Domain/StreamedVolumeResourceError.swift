//
//  StreamedVolumeResourceError.swift
//  MTKCore
//
//  Validation failures for portable streamed volume resources.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import Foundation

package enum StreamedVolumeResourceError: Error, Equatable, LocalizedError {
    case referenceMetadataMismatch

    package var errorDescription: String? {
        switch self {
        case .referenceMetadataMismatch:
            return "The streamed volume descriptor does not match its reference dataset metadata."
        }
    }
}
