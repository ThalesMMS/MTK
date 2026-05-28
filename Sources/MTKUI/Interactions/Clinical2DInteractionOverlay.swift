#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import CoreGraphics
import Foundation
import MTKCore
import SwiftUI
import simd

public enum Clinical2DInteractionKind: String, Hashable, Sendable {
    case drag
    case pinch
    case rotation
    case wheel
}

public struct Clinical2DROIInteraction: Equatable, Sendable {
    public var kind: ViewerROIKind
    public var axis: MTKCore.Axis
    public var sliceIndex: Int
    public var startImagePoint: CGPoint
    public var endImagePoint: CGPoint

    public init(kind: ViewerROIKind,
                axis: MTKCore.Axis,
                sliceIndex: Int,
                startImagePoint: CGPoint,
                endImagePoint: CGPoint) {
        self.kind = kind
        self.axis = axis
        self.sliceIndex = sliceIndex
        self.startImagePoint = startImagePoint
        self.endImagePoint = endImagePoint
    }
}

public enum Clinical2DGestureRoute: Equatable, Sendable {
    case none
    case scrollSlices(Int)
    case adjustWindowLevel(CGSize)
    case rotate(radians: Double)
    case pan(deltaNormalized: SIMD2<Double>)
    case zoom(factor: Double, anchor: SIMD2<Double>)
    case roi(Clinical2DROIInteraction)
}

public struct Clinical2DInteractionRouter: Sendable {
    public var scrollDragPixelsPerStep: CGFloat

    public init(scrollDragPixelsPerStep: CGFloat = 10) {
        self.scrollDragPixelsPerStep = max(scrollDragPixelsPerStep, 1)
    }

    public func routeDrag(tool: Clinical2DTool,
                          axis: MTKCore.Axis,
                          roiKind: ViewerROIKind,
                          sliceIndex: Int,
                          viewportSize: CGSize,
                          transform: Viewer2DTransform,
                          delta: CGSize,
                          startLocation: CGPoint,
                          previousLocation: CGPoint?,
                          currentLocation: CGPoint,
                          isTwoFingerPan: Bool = false) -> Clinical2DGestureRoute {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return .none }
        if isTwoFingerPan, tool != .roi {
            return .pan(deltaNormalized: normalizedDelta(delta, viewportSize: viewportSize))
        }

        switch tool {
        case .scroll:
            let steps = dragScrollSteps(deltaY: delta.height)
            return steps == 0 ? .none : .scrollSlices(steps)
        case .windowLevel:
            guard abs(delta.width) >= 0.5 || abs(delta.height) >= 0.5 else { return .none }
            return .adjustWindowLevel(delta)
        case .rotation:
            guard let radians = rotationDeltaRadians(viewportSize: viewportSize,
                                                     previousLocation: previousLocation ?? startLocation,
                                                     currentLocation: currentLocation),
                  abs(radians) >= 0.0001 else {
                return .none
            }
            return .rotate(radians: radians)
        case .roi, .sync, .reslice:
            return .none
        }
    }

    public func routeCompletedDrag(tool: Clinical2DTool,
                                   axis: MTKCore.Axis,
                                   roiKind: ViewerROIKind,
                                   sliceIndex: Int,
                                   viewportSize: CGSize,
                                   transform: Viewer2DTransform,
                                   startLocation: CGPoint,
                                   endLocation: CGPoint) -> Clinical2DGestureRoute {
        guard tool == .roi,
              let startPoint = normalizedImagePoint(viewportLocation: startLocation,
                                                    viewportSize: viewportSize,
                                                    transform: transform),
              let endPoint = normalizedImagePoint(viewportLocation: endLocation,
                                                  viewportSize: viewportSize,
                                                  transform: transform) else {
            return .none
        }
        return .roi(Clinical2DROIInteraction(kind: roiKind,
                                             axis: axis,
                                             sliceIndex: max(sliceIndex, 0),
                                             startImagePoint: startPoint,
                                             endImagePoint: endPoint))
    }

    public func routeWheel(tool: Clinical2DTool,
                           deltaY: CGFloat,
                           hasPreciseScrollingDeltas: Bool) -> Clinical2DGestureRoute {
        guard tool == .scroll else { return .none }
        let steps = MPRScrollStepMapper.steps(deltaY: deltaY,
                                              hasPreciseScrollingDeltas: hasPreciseScrollingDeltas)
        return steps == 0 ? .none : .scrollSlices(steps)
    }

    public func routeMagnification(factor: CGFloat,
                                   anchor: CGPoint,
                                   tool: Clinical2DTool,
                                   roiCapturingMultiTouch: Bool = false) -> Clinical2DGestureRoute {
        guard !roiCapturingMultiTouch,
              factor.isFinite,
              factor > 0 else {
            return .none
        }
        let normalizedAnchor = SIMD2<Double>(
            Double(min(max(anchor.x, 0), 1)),
            Double(min(max(anchor.y, 0), 1))
        )
        return .zoom(factor: Double(factor), anchor: normalizedAnchor)
    }

    public func routeRotation(tool: Clinical2DTool,
                              radians: CGFloat) -> Clinical2DGestureRoute {
        guard tool == .rotation,
              radians.isFinite,
              abs(radians) >= 0.0001 else {
            return .none
        }
        return .rotate(radians: Double(radians))
    }

    public func normalizedImagePoint(viewportLocation: CGPoint,
                                     viewportSize: CGSize,
                                     transform: Viewer2DTransform) -> CGPoint? {
        guard viewportSize.width > 0,
              viewportSize.height > 0 else {
            return nil
        }
        let zoom = transform.zoom.isFinite && transform.zoom > 0 ? transform.zoom : 1
        var x = Double(viewportLocation.x / viewportSize.width) - 0.5
        var y = Double(viewportLocation.y / viewportSize.height) - 0.5

        x -= transform.pan.x.isFinite ? transform.pan.x : 0
        y -= transform.pan.y.isFinite ? transform.pan.y : 0
        x /= zoom
        y /= zoom

        let rotation = transform.rotationRadians.isFinite ? -transform.rotationRadians : 0
        let cosTheta = cos(rotation)
        let sinTheta = sin(rotation)
        let rotatedX = x * cosTheta - y * sinTheta
        let rotatedY = x * sinTheta + y * cosTheta

        x = transform.isFlippedHorizontally ? -rotatedX : rotatedX
        y = transform.isFlippedVertically ? -rotatedY : rotatedY

        return CGPoint(x: clampUnit(x + 0.5),
                       y: clampUnit(y + 0.5))
    }

    private func dragScrollSteps(deltaY: CGFloat) -> Int {
        let rawSteps = deltaY / scrollDragPixelsPerStep
        if rawSteps >= 1 {
            return Int(rawSteps.rounded(.down))
        }
        if rawSteps <= -1 {
            return Int(rawSteps.rounded(.up))
        }
        return 0
    }

    private func normalizedDelta(_ delta: CGSize,
                                 viewportSize: CGSize) -> SIMD2<Double> {
        SIMD2<Double>(
            Double(delta.width / max(viewportSize.width, 1)),
            Double(delta.height / max(viewportSize.height, 1))
        )
    }

    private func rotationDeltaRadians(viewportSize: CGSize,
                                      previousLocation: CGPoint,
                                      currentLocation: CGPoint) -> Double? {
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let previousVector = CGVector(dx: previousLocation.x - center.x,
                                      dy: previousLocation.y - center.y)
        let currentVector = CGVector(dx: currentLocation.x - center.x,
                                     dy: currentLocation.y - center.y)
        guard hypot(previousVector.dx, previousVector.dy) > 0.5,
              hypot(currentVector.dx, currentVector.dy) > 0.5 else {
            return nil
        }
        let previousAngle = atan2(previousVector.dy, previousVector.dx)
        let currentAngle = atan2(currentVector.dy, currentVector.dx)
        return normalizedRadians(Double(currentAngle - previousAngle))
    }

    private func normalizedRadians(_ value: Double) -> Double {
        var result = value
        while result > .pi { result -= 2 * .pi }
        while result < -.pi { result += 2 * .pi }
        return result
    }

    private func clampUnit(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}

public struct Clinical2DInteractionHandlers {
    public var beginInteraction: @MainActor (Clinical2DInteractionKind) -> Void
    public var endInteraction: @MainActor (Clinical2DInteractionKind) -> Void
    public var scrollSlices: @MainActor (Int) -> Void
    public var adjustWindowLevel: @MainActor (CGSize) -> Void
    public var rotate: @MainActor (Double) -> Void
    public var pan: @MainActor (SIMD2<Double>) -> Void
    public var zoom: @MainActor (Double, SIMD2<Double>) -> Void
    public var commitROI: @MainActor (Clinical2DROIInteraction) -> Void

    public init(beginInteraction: @escaping @MainActor (Clinical2DInteractionKind) -> Void = { _ in },
                endInteraction: @escaping @MainActor (Clinical2DInteractionKind) -> Void = { _ in },
                scrollSlices: @escaping @MainActor (Int) -> Void = { _ in },
                adjustWindowLevel: @escaping @MainActor (CGSize) -> Void = { _ in },
                rotate: @escaping @MainActor (Double) -> Void = { _ in },
                pan: @escaping @MainActor (SIMD2<Double>) -> Void = { _ in },
                zoom: @escaping @MainActor (Double, SIMD2<Double>) -> Void = { _, _ in },
                commitROI: @escaping @MainActor (Clinical2DROIInteraction) -> Void = { _ in }) {
        self.beginInteraction = beginInteraction
        self.endInteraction = endInteraction
        self.scrollSlices = scrollSlices
        self.adjustWindowLevel = adjustWindowLevel
        self.rotate = rotate
        self.pan = pan
        self.zoom = zoom
        self.commitROI = commitROI
    }

    public static var noop: Clinical2DInteractionHandlers {
        Clinical2DInteractionHandlers()
    }
}

public struct Clinical2DInteractionLogger {
    private let logger = Logger(category: "Clinical2DInteraction")

    public init() {}

    public var isEnabled: Bool {
        Logger.twoDInteractionLoggingEnabled || Logger.interactionLoggingEnabled
    }

    public func info(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        logger.info("[MTK2DInteraction] \(message())")
    }
}

@MainActor
public struct Clinical2DInteractionOverlay: View {
    private let surface: MetalViewportSurface
    private let tool: Clinical2DTool
    private let axis: MTKCore.Axis
    private let sliceIndex: Int
    private let roiKind: ViewerROIKind
    private let transform: Viewer2DTransform
    private let router: Clinical2DInteractionRouter
    private let handlers: Clinical2DInteractionHandlers
    private let logger: Clinical2DInteractionLogger
    private let interruptedGestureResetDelay: UInt64 = 750_000_000

    @State private var activeInteractions = Set<Clinical2DInteractionKind>()
    @State private var lastDragTranslation = CGSize.zero
    @State private var lastMagnification: CGFloat = 1
    @State private var lastRotationRadians: CGFloat = 0
    @State private var dragResetTask: Task<Void, Never>?
    @State private var pinchResetTask: Task<Void, Never>?
    @State private var rotationResetTask: Task<Void, Never>?

    public init(surface: MetalViewportSurface,
                tool: Clinical2DTool,
                axis: MTKCore.Axis,
                sliceIndex: Int,
                roiKind: ViewerROIKind,
                transform: Viewer2DTransform,
                router: Clinical2DInteractionRouter = Clinical2DInteractionRouter(),
                handlers: Clinical2DInteractionHandlers = .noop,
                logger: Clinical2DInteractionLogger = Clinical2DInteractionLogger()) {
        self.surface = surface
        self.tool = tool
        self.axis = axis
        self.sliceIndex = sliceIndex
        self.roiKind = roiKind
        self.transform = transform
        self.router = router
        self.handlers = handlers
        self.logger = logger
    }

    public var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("Clinical2DInteractionOverlay")
                .highPriorityGesture(dragGesture(size: proxy.size))
                .simultaneousGesture(magnificationGesture)
                .simultaneousGesture(rotationGesture)
                .onAppear {
                    attachWheelHandler()
                }
                .onChange(of: tool) { _, _ in
                    resetActiveInteractions()
                    attachWheelHandler()
                }
                .onDisappear {
                    surface.onScrollWheel = nil
                    resetActiveInteractions()
                }
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                beginInteractionIfNeeded(.drag)
                scheduleReset(for: .drag)
                let delta = CGSize(width: value.translation.width - lastDragTranslation.width,
                                   height: value.translation.height - lastDragTranslation.height)
                lastDragTranslation = value.translation
                let previousLocation = CGPoint(x: value.location.x - delta.width,
                                               y: value.location.y - delta.height)
                apply(router.routeDrag(tool: tool,
                                       axis: axis,
                                       roiKind: roiKind,
                                       sliceIndex: sliceIndex,
                                       viewportSize: size,
                                       transform: transform,
                                       delta: delta,
                                       startLocation: value.startLocation,
                                       previousLocation: previousLocation,
                                       currentLocation: value.location))
            }
            .onEnded { value in
                apply(router.routeCompletedDrag(tool: tool,
                                                axis: axis,
                                                roiKind: roiKind,
                                                sliceIndex: sliceIndex,
                                                viewportSize: size,
                                                transform: transform,
                                                startLocation: value.startLocation,
                                                endLocation: value.location))
                lastDragTranslation = .zero
                endInteraction(.drag)
            }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                beginInteractionIfNeeded(.pinch)
                scheduleReset(for: .pinch)
                let factor = lastMagnification > 0 ? value.magnification / lastMagnification : value.magnification
                lastMagnification = value.magnification
                apply(router.routeMagnification(factor: factor,
                                                anchor: CGPoint(x: value.startAnchor.x,
                                                                y: value.startAnchor.y),
                                                tool: tool))
            }
            .onEnded { _ in
                lastMagnification = 1
                endInteraction(.pinch)
            }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { angle in
                beginInteractionIfNeeded(.rotation)
                scheduleReset(for: .rotation)
                let radians = CGFloat(angle.radians)
                let delta = radians - lastRotationRadians
                lastRotationRadians = radians
                apply(router.routeRotation(tool: tool, radians: delta))
            }
            .onEnded { _ in
                lastRotationRadians = 0
                endInteraction(.rotation)
            }
    }

    private func attachWheelHandler() {
        surface.onScrollWheel = { deltaY, hasPreciseScrollingDeltas in
            beginInteractionIfNeeded(.wheel)
            apply(router.routeWheel(tool: tool,
                                    deltaY: deltaY,
                                    hasPreciseScrollingDeltas: hasPreciseScrollingDeltas))
            endInteraction(.wheel)
        }
    }

    private func apply(_ route: Clinical2DGestureRoute) {
        switch route {
        case .none:
            return
        case .scrollSlices(let steps):
            logger.info("route=scroll steps=\(steps) tool=\(tool.rawValue)")
            handlers.scrollSlices(steps)
        case .adjustWindowLevel(let delta):
            logger.info("route=windowLevel dx=\(delta.width) dy=\(delta.height)")
            handlers.adjustWindowLevel(delta)
        case .rotate(let radians):
            logger.info("route=rotation radians=\(radians)")
            handlers.rotate(radians)
        case .pan(let deltaNormalized):
            logger.info("route=pan dx=\(deltaNormalized.x) dy=\(deltaNormalized.y)")
            handlers.pan(deltaNormalized)
        case .zoom(let factor, let anchor):
            logger.info("route=zoom factor=\(factor) anchor=\(anchor)")
            handlers.zoom(factor, anchor)
        case .roi(let interaction):
            logger.info("route=roi kind=\(interaction.kind.rawValue) axis=\(interaction.axis)")
            handlers.commitROI(interaction)
        }
    }

    private func beginInteractionIfNeeded(_ kind: Clinical2DInteractionKind) {
        guard activeInteractions.insert(kind).inserted else { return }
        logger.info("begin kind=\(kind.rawValue) tool=\(tool.rawValue)")
        handlers.beginInteraction(kind)
    }

    private func endInteraction(_ kind: Clinical2DInteractionKind) {
        resetTask(for: kind)?.cancel()
        clearResetTask(for: kind)
        guard activeInteractions.remove(kind) != nil else { return }
        logger.info("end kind=\(kind.rawValue) tool=\(tool.rawValue)")
        handlers.endInteraction(kind)
    }

    private func scheduleReset(for kind: Clinical2DInteractionKind) {
        resetTask(for: kind)?.cancel()
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: interruptedGestureResetDelay)
            } catch {
                return
            }
            endInteraction(kind)
        }
        setResetTask(task, for: kind)
    }

    private func resetActiveInteractions() {
        dragResetTask?.cancel()
        pinchResetTask?.cancel()
        rotationResetTask?.cancel()
        dragResetTask = nil
        pinchResetTask = nil
        rotationResetTask = nil
        lastDragTranslation = .zero
        lastMagnification = 1
        lastRotationRadians = 0
        let active = activeInteractions
        activeInteractions.removeAll()
        for kind in active {
            logger.info("cancel kind=\(kind.rawValue) tool=\(tool.rawValue)")
            handlers.endInteraction(kind)
        }
    }

    private func resetTask(for kind: Clinical2DInteractionKind) -> Task<Void, Never>? {
        switch kind {
        case .drag:
            return dragResetTask
        case .pinch:
            return pinchResetTask
        case .rotation:
            return rotationResetTask
        case .wheel:
            return nil
        }
    }

    private func setResetTask(_ task: Task<Void, Never>?,
                              for kind: Clinical2DInteractionKind) {
        switch kind {
        case .drag:
            dragResetTask = task
        case .pinch:
            pinchResetTask = task
        case .rotation:
            rotationResetTask = task
        case .wheel:
            break
        }
    }

    private func clearResetTask(for kind: Clinical2DInteractionKind) {
        setResetTask(nil, for: kind)
    }
}
#endif
