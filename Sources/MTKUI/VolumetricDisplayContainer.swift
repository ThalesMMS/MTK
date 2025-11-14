//  VolumetricDisplayContainer.swift
//  MTK
//  Simple container that hosts the render surface and optional overlays.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public struct VolumetricDisplayContainer<Overlays: View>: View {
    @ObservedObject private var controller: VolumetricSceneController
    private let overlays: () -> Overlays

    public init(controller: VolumetricSceneController,
                @ViewBuilder overlays: @escaping () -> Overlays) {
        self.controller = controller
        self.overlays = overlays
    }

    public var body: some View {
        ZStack {
            RenderSurfaceView(surface: controller.surface)
                .accessibilityIdentifier("VolumetricRenderSurface")
            overlays()
        }
    }
}

public extension VolumetricDisplayContainer where Overlays == EmptyView {
    init(controller: VolumetricSceneController) {
        self.init(controller: controller) { EmptyView() }
    }
}
#endif
