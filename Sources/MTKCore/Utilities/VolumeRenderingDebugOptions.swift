//
//  VolumeRenderingDebugOptions.swift
//  MTK
//
//  Provides diagnostic toggles for the Metal pipelines so hosts can surface
//  verbose logging, histogram tweaks, and density debugging without touching
//  global app config.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation

public struct VolumeRenderingDebugOptions: Sendable {
    public var isDebugMode: Bool
    public var histogramBinCount: Int
    public var enableDensityDebug: Bool

    public init(isDebugMode: Bool = false,
                histogramBinCount: Int = 512,
                enableDensityDebug: Bool = false) {
        self.isDebugMode = isDebugMode
        self.histogramBinCount = histogramBinCount
        self.enableDensityDebug = enableDensityDebug
    }
}
