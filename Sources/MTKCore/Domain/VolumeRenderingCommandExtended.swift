//
//  VolumeRenderingCommandExtended.swift
//  MTK
//
//  Extended volume rendering commands for missing APIs
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd

public enum VolumeRenderingCommandExtended: Sendable, Equatable {
    // Window/Intensity controls
    case setHuWindow(min: Int32, max: Int32)
    case setEarlyTerminationThreshold(Float)
    case setDensityGate(floor: Float, ceil: Float)
    case setHuGate(enabled: Bool, minHU: Int32, maxHU: Int32)
    
    // Channel controls
    case updateChannelIntensities([Float])
    case setToneCurveControlPoints([SIMD2<Float>], channel: Int)
    case setToneCurvePresetKey(String, channel: Int)
    case setToneCurveGain(Float, channel: Int)
    
    // Rendering controls
    case setAdaptiveEnabled(Bool)
    case setAdaptiveThreshold(Float)
    case setJitterAmount(Float)
    case setLighting(Bool)
    case setStep(Float)
    case setShift(Float)
    case setRenderMethod(Int)
    
    // MPR controls
    case setMPRBlend(Float)
    
    // Clip controls
    case updateClipBounds(xMin: Float, xMax: Float, yMin: Float, yMax: Float, zMin: Float, zMax: Float)
    case resetClipBounds
    case setClipPlanePreset(Int)
    case setClipPlaneOffset(Float)
    case alignClipBoxToView
    case alignClipPlaneToView
}
