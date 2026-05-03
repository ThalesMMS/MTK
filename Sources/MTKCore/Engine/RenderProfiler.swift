//
//  RenderProfiler.swift
//  MTK
//
//  Owns per-frame profiling scope creation and sample recording.
//  Extracted from MTKRenderingEngine to keep profiling concerns isolated.
//

import Foundation
@preconcurrency import Metal

struct RenderProfiler: Sendable {
    struct Scope: Sendable {
        let measureUploadTime: Bool
        let measureRenderTime: Bool
        let measurePresentTime: Bool

        private let renderStartedAt: CFAbsoluteTime?

        init(options: ProfilingOptions) {
            self.measureUploadTime = options.measureUploadTime
            self.measureRenderTime = options.measureRenderTime
            self.measurePresentTime = options.measurePresentTime
            self.renderStartedAt = options.measureRenderTime ? CFAbsoluteTimeGetCurrent() : nil
        }

        func renderDuration() -> TimeInterval? {
            renderStartedAt.map { CFAbsoluteTimeGetCurrent() - $0 }
        }
    }

    func makeScope(options: ProfilingOptions) -> Scope {
        Scope(options: options)
    }

    func recordRouteResolution(
        startedAt: CFAbsoluteTime?,
        route: RenderRoute,
        viewportSize: CGSize,
        viewportID: ViewportID,
        viewportTypeName: String,
        qualityName: String,
        renderModeName: String,
        options: ProfilingOptions,
        device: any MTLDevice
    ) {
        guard options.isEnabled(stage: .renderGraphRoute) else {
            return
        }

        let clampedSize = VolumetricMath.clampViewportSize(viewportSize)
        let elapsed = startedAt.map { ClinicalProfiler.milliseconds(from: $0) } ?? 0
        ClinicalProfiler.shared.recordSample(
            stage: .renderGraphRoute,
            cpuTime: elapsed,
            viewport: ProfilingViewportContext(
                resolutionWidth: clampedSize.width,
                resolutionHeight: clampedSize.height,
                viewportType: viewportTypeName,
                quality: qualityName,
                renderMode: renderModeName
            ),
            routeName: route.profilingName,
            metadata: [
                "path": "MTKRenderingEngine.resolveRoute",
                "viewportID": String(describing: viewportID),
                "renderPassPipeline": route.passPipelineName
            ],
            device: device
        )
    }

    func recordMemorySnapshot(
        resourceManager: VolumeResourceManager,
        route: RenderRoute,
        viewportSize: CGSize,
        viewportID: ViewportID,
        viewportTypeName: String,
        qualityName: String,
        renderModeName: String,
        options: ProfilingOptions
    ) {
        guard options.isEnabled(stage: .memorySnapshot) else {
            return
        }

        let clampedSize = VolumetricMath.clampViewportSize(viewportSize)
        let context = ProfilingViewportContext(
            resolutionWidth: clampedSize.width,
            resolutionHeight: clampedSize.height,
            viewportType: viewportTypeName,
            quality: qualityName,
            renderMode: renderModeName
        )
        ClinicalProfiler.shared.recordMemorySnapshot(
            from: resourceManager,
            viewport: context,
            metadata: [
                "path": "MTKRenderingEngine.resourceMetrics",
                "renderGraphRoute": route.profilingName,
                "renderPassPipeline": route.passPipelineName,
                "viewportID": String(describing: viewportID)
            ]
        )
    }

    func recordMPRReslice(
        startedAt: CFAbsoluteTime,
        frameTexture: any MTLTexture,
        viewportSize: CGSize,
        route: RenderRoute,
        viewportID: ViewportID,
        viewportTypeName: String,
        qualityName: String,
        renderModeName: String,
        slabThickness: Int,
        slabSteps: Int,
        path: String,
        options: ProfilingOptions,
        device: any MTLDevice
    ) {
        guard options.isEnabled(stage: .mprReslice) else {
            return
        }

        let clampedSize = VolumetricMath.clampViewportSize(viewportSize)
        ClinicalProfiler.shared.recordSample(
            stage: .mprReslice,
            cpuTime: ClinicalProfiler.milliseconds(from: startedAt),
            memory: ResourceMemoryEstimator.estimate(for: frameTexture),
            viewport: ProfilingViewportContext(
                resolutionWidth: clampedSize.width,
                resolutionHeight: clampedSize.height,
                viewportType: viewportTypeName,
                quality: qualityName,
                renderMode: renderModeName
            ),
            metadata: [
                "path": path,
                "renderGraphRoute": route.profilingName,
                "renderPassPipeline": route.passPipelineName,
                "viewportID": String(describing: viewportID),
                "slabThickness": String(slabThickness),
                "slabSteps": String(slabSteps)
            ],
            device: device
        )
    }
}
