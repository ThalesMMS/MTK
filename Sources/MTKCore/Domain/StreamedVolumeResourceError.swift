//
//  StreamedVolumeResourceError.swift
//  MTK
//
//  Validation failures for portable streamed volume resources.
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
