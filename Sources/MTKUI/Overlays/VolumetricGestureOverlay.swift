//  VolumetricGestureOverlay.swift
//  MTK
//  Lightweight SwiftUI wrapper that attaches the built-in gesture modifier.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

@MainActor
public struct VolumetricGestureOverlay: View {
    private let controller: VolumetricSceneController
    private let configuration: VolumeGestureConfiguration
    @StateObject private var stateStorage: VolumeGestureState

    public init(controller: VolumetricSceneController,
                configuration: VolumeGestureConfiguration = .default,
                state: VolumeGestureState? = nil) {
        self.controller = controller
        self.configuration = configuration
        _stateStorage = StateObject(wrappedValue: state ?? VolumeGestureState())
    }

    public var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .volumeGestures(controller: controller,
                            state: stateStorage,
                            configuration: configuration)
            .accessibilityHidden(true)
    }
}
#endif
