//
//  RenderQualityScheduler.swift
//  MTKCore
//
//  Debounced preview/HQ quality scheduler for the Metal-native rendering path.
//

import Combine
import Foundation

@MainActor
public protocol RenderQualityScheduling: AnyObject {
    var state: RenderQualityState { get }
    var currentParameters: RenderQualityParameters { get }

    func beginInteraction()
    func endInteraction()
    func forceSettled()
}

@MainActor
public final class RenderQualityScheduler: ObservableObject, RenderQualityScheduling {
    @Published public private(set) var state: RenderQualityState

    public private(set) var baseSamplingStep: Float
    public private(set) var baseSlabSteps: Int
    public let interactionFactor: Float

    private let settlingDelayNanoseconds: UInt64
    private var settlingTask: Task<Void, Never>?
    private var activeInteractionCount = 0

    public init(baseSamplingStep: Float = 512,
                baseSlabSteps: Int = 1,
                interactionFactor: Float = 0.5,
                settlingDelayNanoseconds: UInt64 = 250_000_000) {
        self.state = .settled
        self.baseSamplingStep = max(baseSamplingStep, 1)
        self.baseSlabSteps = VolumetricMath.sanitizeSteps(baseSlabSteps)
        self.interactionFactor = VolumetricMath.clampFloat(interactionFactor, lower: 0.1, upper: 1)
        self.settlingDelayNanoseconds = settlingDelayNanoseconds
    }

    deinit {
        settlingTask?.cancel()
    }

    public var currentParameters: RenderQualityParameters {
        switch state {
        case .interacting, .settling:
            return RenderQualityParameters(
                volumeSamplingStep: max(1, baseSamplingStep * interactionFactor),
                mprSlabStepsFactor: interactionFactor,
                qualityTier: .preview
            )
        case .settled:
            return RenderQualityParameters(
                volumeSamplingStep: max(baseSamplingStep, 1),
                mprSlabStepsFactor: 1,
                qualityTier: .production
            )
        }
    }

    public var currentSlabSteps: Int {
        let scaled = Float(baseSlabSteps) * currentParameters.mprSlabStepsFactor
        return VolumetricMath.sanitizeSteps(Int(round(scaled)))
    }

    public func setBaseSamplingStep(_ step: Float) {
        baseSamplingStep = max(step, 1)
    }

    public func setBaseSlabSteps(_ steps: Int) {
        baseSlabSteps = VolumetricMath.sanitizeSteps(steps)
    }

    public func beginInteraction() {
        activeInteractionCount += 1
        settlingTask?.cancel()
        settlingTask = nil
        setState(.interacting)
    }

    public func endInteraction() {
        guard activeInteractionCount > 0 else { return }
        activeInteractionCount -= 1
        guard activeInteractionCount == 0, state != .settled else { return }
        settlingTask?.cancel()
        setState(.settling)
        let delay = settlingDelayNanoseconds
        settlingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishSettling()
        }
    }

    public func forceSettled() {
        activeInteractionCount = 0
        settlingTask?.cancel()
        settlingTask = nil
        setState(.settled)
    }

    private func finishSettling() {
        guard activeInteractionCount == 0 else { return }
        settlingTask = nil
        setState(.settled)
    }

    private func setState(_ newState: RenderQualityState) {
        guard state != newState else { return }
        state = newState
    }
}
