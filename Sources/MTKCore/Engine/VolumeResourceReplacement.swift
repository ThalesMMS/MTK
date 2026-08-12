//
//  VolumeResourceReplacement.swift
//  MTKCore
//
//  Transaction token for swapping one shared volume across engine viewports.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import Foundation

package struct VolumeResourceReplacement: Sendable {
    package struct PreviousState: Sendable {
        package let viewport: ViewportID
        package let state: MTKRenderingEngine.ViewportState
    }

    package let previousStates: [PreviousState]
    package let replacementHandle: VolumeResourceHandle
}
