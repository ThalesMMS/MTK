//
//  DicomDecoderSeriesLoader.swift
//  MTK
//
//  Swift implementation of DicomSeriesLoading backed by DICOM-Decoder package
//  Streams slice data and metadata without relying on GDCM bridge
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd
import DicomCore

/// Swift implementation of `DicomSeriesLoading` backed by the pure-Swift DICOM-Decoder package.
/// It streams slice data and metadata to `DicomVolumeLoader` without relying on the GDCM bridge.
public final class DicomDecoderSeriesLoader: DicomSeriesLoading {
    private let loader = DicomCore.DicomSeriesLoader()
    private var cachedVolume: BridgedVolume?

    public init() {}

    public func loadSeries(at url: URL,
                           progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        guard url.isFileURL else {
            throw NSError(domain: "br.thalesmms.dicom.decoder",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "URL fornecida não é um caminho local."])
        }

        cachedVolume = nil
        let volume = try loader.loadSeries(in: url, progress: { [weak self] fraction, slices, sliceData, seriesVolume in
            guard let self else { return }
            let bridged = self.bridge(seriesVolume)
            progress?(fraction, UInt(slices), sliceData, bridged)
        })

        return bridge(volume)
    }

    private func bridge(_ volume: DicomSeriesVolume) -> BridgedVolume {
        if let cached = cachedVolume, cached.referencesSameVolume(as: volume) {
            return cached
        }
        let bridged = BridgedVolume(volume: volume)
        cachedVolume = bridged
        return bridged
    }
}

private final class BridgedVolume: DICOMSeriesVolumeProtocol {
    private let volume: DicomSeriesVolume

    init(volume: DicomSeriesVolume) {
        self.volume = volume
    }

    func referencesSameVolume(as other: DicomSeriesVolume) -> Bool {
        volume.voxels == other.voxels && volume.width == other.width && volume.height == other.height && volume.depth == other.depth
    }

    var bitsAllocated: Int { volume.bitsAllocated }
    var width: Int { volume.width }
    var height: Int { volume.height }
    var depth: Int { volume.depth }
    var spacingX: Double { volume.spacing.x }
    var spacingY: Double { volume.spacing.y }
    var spacingZ: Double { volume.spacing.z }
    var orientation: simd_float3x3 {
        let row = SIMD3<Float>(Float(volume.orientation.columns.0.x),
                               Float(volume.orientation.columns.0.y),
                               Float(volume.orientation.columns.0.z))
        let column = SIMD3<Float>(Float(volume.orientation.columns.1.x),
                                  Float(volume.orientation.columns.1.y),
                                  Float(volume.orientation.columns.1.z))
        let normal = SIMD3<Float>(Float(volume.orientation.columns.2.x),
                                  Float(volume.orientation.columns.2.y),
                                  Float(volume.orientation.columns.2.z))
        return simd_float3x3(columns: (row, column, normal))
    }
    var origin: SIMD3<Float> {
        SIMD3<Float>(Float(volume.origin.x),
                     Float(volume.origin.y),
                     Float(volume.origin.z))
    }
    var rescaleSlope: Double { volume.rescaleSlope }
    var rescaleIntercept: Double { volume.rescaleIntercept }
    var isSignedPixel: Bool { volume.isSignedPixel }
    var seriesDescription: String { volume.seriesDescription }
}
