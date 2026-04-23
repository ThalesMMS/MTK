//
//  ProfilingContext+MTK.swift
//  MTK
//
//  Helpers for mapping rendering types into profiler labels.
//

import Foundation

extension RenderRoute {
    public var profilingName: String {
        switch viewportType {
        case .volume3D:
            return "volume3D.\(compositing?.profilingName ?? "frontToBack")"
        case .projection(let mode):
            return "projection.\(mode.profilingName)"
        case .mpr(let axis):
            return "mpr.\(axis.profilingName)"
        }
    }
}

extension ProfilingViewportContext {
    init(width: Int,
         height: Int,
         viewportType: String,
         quality: VolumeRenderRequest.Quality,
         renderMode: VolumeRenderRequest.Compositing) {
        self.init(resolutionWidth: width,
                  resolutionHeight: height,
                  viewportType: viewportType,
                  quality: quality.profilingName,
                  renderMode: renderMode.profilingName)
    }

    init(width: Int,
         height: Int,
         viewportType: String,
         quality: String,
         renderMode: MPRBlendMode) {
        self.init(resolutionWidth: width,
                  resolutionHeight: height,
                  viewportType: viewportType,
                  quality: quality,
                  renderMode: renderMode.profilingName)
    }
}

extension VolumeRenderRequest.Quality {
    var profilingName: String {
        switch self {
        case .preview:
            return "preview"
        case .interactive:
            return "interactive"
        case .production:
            return "production"
        }
    }
}

extension VolumeRenderRequest.Compositing {
    var profilingName: String {
        switch self {
        case .maximumIntensity:
            return "maximumIntensity"
        case .minimumIntensity:
            return "minimumIntensity"
        case .averageIntensity:
            return "averageIntensity"
        case .frontToBack:
            return "frontToBack"
        }
    }
}

extension MPRBlendMode {
    var profilingName: String {
        switch self {
        case .single:
            return "single"
        case .maximum:
            return "maximum"
        case .minimum:
            return "minimum"
        case .average:
            return "average"
        }
    }
}

extension ViewportType {
    var profilingName: String {
        switch self {
        case .volume3D:
            return "volume3D"
        case .mpr(let axis):
            return "mpr.\(axis.profilingName)"
        case .projection(let mode):
            return "projection.\(mode.profilingName)"
        }
    }

    var renderModeName: String {
        switch self {
        case .volume3D:
            return "frontToBack"
        case .mpr:
            return "mpr"
        case .projection(let mode):
            return mode.profilingName
        }
    }
}

extension Axis {
    var profilingName: String {
        switch self {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }
}

extension ProjectionMode {
    var profilingName: String {
        switch self {
        case .mip:
            return "mip"
        case .minip:
            return "minip"
        case .aip:
            return "aip"
        }
    }
}
