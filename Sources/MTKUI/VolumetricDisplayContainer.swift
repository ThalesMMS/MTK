//  VolumetricDisplayContainer.swift
//  MTK
//  Simple container that hosts the render surface and optional overlays.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI
import OSLog

@MainActor
public struct VolumetricDisplayContainer<Overlays: View>: View {
    @ObservedObject private var controller: VolumetricSceneController
    @State private var lastLoggedSize: CGSize = .zero
    private let logger = Logger(subsystem: "com.isis.viewer", category: "VolumetricDisplayContainer")
    private let overlays: () -> Overlays

    public init(controller: VolumetricSceneController,
                @ViewBuilder overlays: @escaping () -> Overlays) {
        self.controller = controller
        self.overlays = overlays
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                RenderSurfaceView(surface: controller.surface)
                    .accessibilityIdentifier("VolumetricRenderSurface")
                overlays()
            }
            .onAppear { logSize(proxy.size) }
            .onChange(of: proxy.size) { logSize($0) }
        }
    }
}

public extension VolumetricDisplayContainer where Overlays == EmptyView {
    init(controller: VolumetricSceneController) {
        self.init(controller: controller) { EmptyView() }
    }
}

private extension VolumetricDisplayContainer {
    func logSize(_ size: CGSize) {
        guard size != lastLoggedSize else { return }
        lastLoggedSize = size
        if size.width <= 1 || size.height <= 1 {
            logger.warning("Volumetric container has degenerate size width=\(size.width) height=\(size.height)")
        } else {
            logger.debug("Volumetric container size width=\(size.width) height=\(size.height)")
        }
    }
}
#endif
