//
//  ViewportTypes.swift
//  MTK
//
//  Core viewport identity and configuration types for MTKRenderingEngine.
//

import CoreGraphics
import Foundation

public struct ViewportID: Hashable, Sendable {
    private let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }
}

public enum Axis: CaseIterable, Hashable, Sendable {
    case axial
    case coronal
    case sagittal
}

public enum ProjectionMode: CaseIterable, Hashable, Sendable {
    case mip
    case minip
    case aip

    public var compositing: VolumeRenderRequest.Compositing {
        switch self {
        case .mip:
            return .maximumIntensity
        case .minip:
            return .minimumIntensity
        case .aip:
            return .averageIntensity
        }
    }
}

public enum ViewportType: Hashable, Sendable {
    case volume3D
    case mpr(axis: Axis)
    case projection(mode: ProjectionMode)
}

public struct ViewportDescriptor: Hashable, Sendable {
    public var type: ViewportType
    public var initialSize: CGSize
    public var label: String?

    public init(type: ViewportType,
                initialSize: CGSize,
                label: String? = nil) {
        self.type = type
        self.initialSize = initialSize
        self.label = label
    }
}

extension Axis {
    var mprPlaneAxis: MPRPlaneAxis {
        switch self {
        case .axial:
            return .z
        case .coronal:
            return .y
        case .sagittal:
            return .x
        }
    }
}
