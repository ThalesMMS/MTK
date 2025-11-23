//
//  VolumetricSceneController+MPS.swift
//  MetalVolumetrics
//
//  Metal Performance Shaders support extracted from the main controller.
//
#if os(iOS) || os(macOS)
import Foundation
import CoreGraphics
import SceneKit
import simd
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif
import MTKCore
import MTKSceneKit

#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
public extension VolumetricSceneController {
    @MainActor
    public final class MPSDisplayAdapter: NSObject, MTKViewDelegate, RenderSurface {
        private let metalView: MTKView
        private let commandQueue: any MTLCommandQueue
        private var histogram: MPSVolumeRenderer.HistogramResult?
        private var dataset: VolumeDataset?
        private var transferFunction: TransferFunction?
        private var configuration: DisplayConfiguration?
        private var volumeMethod: VolumeCubeMaterial.Method = .dvr
        private var renderMode: VolumetricRenderMode = .active
        private var lightingEnabled = true
        private var huGateEnabled = true
        private var huWindow: (min: Int32, max: Int32)?
        private var adaptiveSamplingEnabled = true
        private var adaptiveSamplingStep: Float = 512
        private var samplingStep: Float = 512
        private var projectionsUseTransferFunction = false
        private var densityGate: (floor: Float, ceil: Float) = (0.02, 1.0)
        private var projectionHuGate: (enabled: Bool, min: Int32, max: Int32) = (false, -1024, 3071)
        private var adaptiveInteractionActive = false
        private var isBackendActive = false
        private var raySamples: [MPSVolumeRenderer.RayCastingSample] = []

        public init(device: any MTLDevice, commandQueue: any MTLCommandQueue) {
            self.commandQueue = commandQueue
            self.metalView = MTKView(frame: .zero, device: device)
            super.init()
            metalView.translatesAutoresizingMaskIntoConstraints = false
            metalView.framebufferOnly = false
            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = false
            metalView.preferredFramesPerSecond = 60
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
            metalView.delegate = self
            metalView.isHidden = true
        }

        public var view: PlatformView { metalView }
        public var mtkView: MTKView { metalView }

        func updateDataset(_ dataset: VolumeDataset?) {
            self.dataset = dataset
            refreshClearColor()
        }

        // MARK: - RenderSurface

        public func display(_ image: CGImage) {
#if os(macOS)
            metalView.layer?.contents = image
#else
            metalView.layer.contents = image
#endif
        }

        public func setContentScale(_ scale: CGFloat) {
#if os(iOS)
            metalView.contentScaleFactor = scale
#elseif os(macOS)
            metalView.layer?.contentsScale = scale
#endif
        }

        func updateHistogram(_ histogram: MPSVolumeRenderer.HistogramResult?) {
            self.histogram = histogram
            refreshClearColor()
        }

        func updateTransferFunction(_ transferFunction: TransferFunction?) {
            self.transferFunction = transferFunction
            refreshClearColor()
        }

        func updateDisplayConfiguration(_ configuration: DisplayConfiguration?) {
            self.configuration = configuration
            switch configuration {
            case let .volume(method):
                volumeMethod = method
            default:
                break
            }
            refreshClearColor()
        }

        func updateVolumeMethod(_ method: VolumeCubeMaterial.Method) {
            volumeMethod = method
            refreshClearColor()
        }

        func updateRenderMethod(_ method: VolumeCubeMaterial.Method) {
            volumeMethod = method
            refreshClearColor()
        }

        func updateHuGate(enabled: Bool) {
            huGateEnabled = enabled
            refreshClearColor()
        }

        func updateHuWindow(min: Int32, max: Int32) {
            huWindow = (min, max)
            refreshClearColor()
        }

        func updateAdaptiveSampling(_ enabled: Bool) {
            adaptiveSamplingEnabled = enabled
            refreshClearColor()
        }

        func updateAdaptiveSamplingStep(_ step: Float) {
            adaptiveSamplingStep = step
            refreshClearColor()
        }

        func updateSamplingStep(_ step: Float) {
            samplingStep = step
            refreshClearColor()
        }

        func updateProjectionsUseTransferFunction(_ enabled: Bool) {
            projectionsUseTransferFunction = enabled
            refreshClearColor()
        }

        func updateDensityGate(floor: Float, ceil: Float) {
            densityGate = (floor, ceil)
            refreshClearColor()
        }

        func updateProjectionHuGate(enabled: Bool, min: Int32, max: Int32) {
            projectionHuGate = (enabled, min, max)
            refreshClearColor()
        }

        func updateLighting(enabled: Bool) {
            lightingEnabled = enabled
            refreshClearColor()
        }

        func setAdaptiveInteraction(isActive: Bool) {
            adaptiveInteractionActive = isActive
            refreshClearColor()
        }

        func setRenderMode(_ mode: VolumetricRenderMode) {
            renderMode = mode
            metalView.isPaused = mode == .paused || !isBackendActive
        }

        func setActive(_ active: Bool) {
            isBackendActive = active
            metalView.isHidden = !active
            metalView.isPaused = !active || renderMode == .paused
            refreshClearColor()
        }

        func updateRayCasting(samples: [MPSVolumeRenderer.RayCastingSample]) {
            raySamples = samples
            refreshClearColor()
        }

        public func draw(in view: MTKView) {
            guard isBackendActive else { return }
            guard
                let descriptor = view.currentRenderPassDescriptor,
                let drawable = view.currentDrawable,
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No-op: adapter does not rely on drawable size for now.
        }

        @_spi(Testing)
        public func debugTransferFunction() -> TransferFunction? {
            transferFunction
        }

        @_spi(Testing)
        public func debugClearColor() -> MTLClearColor {
            metalView.clearColor
        }

        @_spi(Testing)
        public func debugResolvedBrightness() -> Float {
            resolvedBrightness()
        }

        private func refreshClearColor() {
            let hue = resolvedHue()
            let saturation = resolvedSaturation()
            let brightness = resolvedBrightness()
            let rgb = hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
            metalView.clearColor = MTLClearColorMake(Double(rgb.r), Double(rgb.g), Double(rgb.b), 1)
        }

        private func resolvedHue() -> Float {
            switch configuration {
            case .volume:
                return hue(for: volumeMethod)
            case .mpr:
                return 0.08
            case .none:
                return hue(for: volumeMethod)
            }
        }

        private func hue(for method: VolumeCubeMaterial.Method) -> Float {
            return 0.58
        }

        private func resolvedSaturation() -> Float {
            let base: Float
            switch configuration {
            case .volume:
                base = 0.65
            case .mpr:
                base = 0.35
            case .none:
                base = 0.4
            }
            let gateAdjustment: Float = huGateEnabled ? 0.05 : -0.1
            let adaptiveAdjustment: Float = adaptiveSamplingEnabled ? 0 : -0.1
            let interactionAdjustment: Float = adaptiveInteractionActive ? -0.25 : 0
            let projectionAdjustment: Float = projectionsUseTransferFunction ? 0.1 : 0
            let saturation = clampFloat(base + gateAdjustment + adaptiveAdjustment + interactionAdjustment + projectionAdjustment,
                                       lower: Float(0.05),
                                       upper: Float(1))
            return saturation
        }

        private func resolvedBrightness() -> Float {
            let mean = histogramMean()
            let shift = clampFloat((transferFunction?.shift ?? 0 + 1024) / 4096, lower: 0, upper: 1)
            let lighting: Float = lightingEnabled ? 0.12 : -0.08
            let adaptive: Float = adaptiveInteractionActive ? 0.2 : 0
            let stepImpact = clampFloat(1 - (adaptiveSamplingStep / max(samplingStep, 1)), lower: 0, upper: Float(0.25))
            let rayContribution: Float = raySamples.isEmpty ? 0 : min(Float(0.15), averageRayEntry())
            let base = Float(0.35) + mean * Float(0.45) + shift * Float(0.25)
            let contributions = lighting + adaptive + stepImpact + rayContribution
            let brightness = clampFloat(base + contributions,
                                        lower: Float(0.1),
                                        upper: Float(1))
            return brightness
        }

        private func averageRayEntry() -> Float {
            guard !raySamples.isEmpty else { return 0 }
            let total = raySamples.reduce(0) { $0 + $1.entryDistance }
            let average = total / Float(raySamples.count)
            let normalized = clampFloat(average / max(1, adaptiveSamplingStep), lower: 0, upper: 1)
            return normalized * 0.5
        }

        private func histogramMean() -> Float {
            guard let histogram else { return 0.45 }
            let total = histogram.bins.reduce(0, +)
            guard total > 0 else { return 0.45 }
            let range = histogram.intensityRange.upperBound - histogram.intensityRange.lowerBound
            guard range > 0 else { return 0.45 }
            let step = range / Float(histogram.bins.count)
            var weighted: Float = 0
            for (index, bin) in histogram.bins.enumerated() {
                let center = histogram.intensityRange.lowerBound + (Float(index) + 0.5) * step
                weighted += center * bin
            }
            let mean = weighted / total
            let normalized = (mean - histogram.intensityRange.lowerBound) / range
            return clampFloat(normalized, lower: 0, upper: 1)
        }

        private func hsbToRGB(hue: Float, saturation: Float, brightness: Float) -> (r: Float, g: Float, b: Float) {
            let h = (hue - floor(hue)) * 6
            let c = brightness * saturation
            let x = c * (1 - abs(fmodf(h, 2) - 1))
            let m = brightness - c

            let (rp, gp, bp): (Float, Float, Float)
            switch h {
            case ..<1:
                (rp, gp, bp) = (c, x, 0)
            case ..<2:
                (rp, gp, bp) = (x, c, 0)
            case ..<3:
                (rp, gp, bp) = (0, c, x)
            case ..<4:
                (rp, gp, bp) = (0, x, c)
            case ..<5:
                (rp, gp, bp) = (x, 0, c)
            default:
                (rp, gp, bp) = (c, 0, x)
            }

            return (rp + m, gp + m, bp + m)
        }

    }
}
#endif
#endif
