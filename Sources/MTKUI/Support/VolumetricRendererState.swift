//
//  VolumetricRendererState.swift
//  MTKUI
//
//  Lightweight state snapshot broadcasted by VolumetricSceneCoordinator so that
//  UI layers can observe dataset/HU/TF updates without spelunking inside app targets.
//

import Foundation
import MTKCore
import MTKSceneKit

public struct VolumetricRendererState {
    public struct DatasetSummary: Equatable {
        public let dimensions: VolumeDimensions
        public let spacing: VolumeSpacing
        public let intensityRange: ClosedRange<Int32>
        public let orientation: VolumeOrientation

        public init(dimensions: VolumeDimensions,
                    spacing: VolumeSpacing,
                    intensityRange: ClosedRange<Int32>,
                    orientation: VolumeOrientation) {
            self.dimensions = dimensions
            self.spacing = spacing
            self.intensityRange = intensityRange
            self.orientation = orientation
        }
    }

    public var dataset: DatasetSummary?
    public var huWindow: VolumeCubeMaterial.HuWindowMapping?
    public var transferFunction: TransferFunction?
    public var normalizedMprPositions: [VolumetricSceneController.Axis: Float]

    public init(dataset: DatasetSummary? = nil,
                huWindow: VolumeCubeMaterial.HuWindowMapping? = nil,
                transferFunction: TransferFunction? = nil,
                normalizedMprPositions: [VolumetricSceneController.Axis: Float] = [:]) {
        self.dataset = dataset
        self.huWindow = huWindow
        self.transferFunction = transferFunction
        self.normalizedMprPositions = normalizedMprPositions
    }

    public func normalizedPosition(for axis: VolumetricSceneController.Axis) -> Float {
        normalizedMprPositions[axis] ?? 0.5
    }

    public struct ToneCurveSnapshot: Equatable {
        public let index: Int
        public let controlPoints: [AdvancedToneCurvePoint]
        public let histogram: [UInt32]
        public let presetKey: String
        public let gain: Float

        public init(index: Int,
                    controlPoints: [AdvancedToneCurvePoint],
                    histogram: [UInt32],
                    presetKey: String,
                    gain: Float) {
            self.index = index
            self.controlPoints = controlPoints
            self.histogram = histogram
            self.presetKey = presetKey
            self.gain = gain
        }
    }

    public var toneCurves: [ToneCurveSnapshot] = []
    public var clipBounds: ClipBoundsSnapshot?
    public var clipPlane: ClipPlaneSnapshot?
}
