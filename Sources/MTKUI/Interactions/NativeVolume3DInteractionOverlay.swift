#if canImport(SwiftUI) && os(iOS)
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

public enum NativeVolume3DInteractionMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case orbit
    case pan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orbit:
            return "Orbit"
        case .pan:
            return "Pan"
        }
    }
}

@MainActor
public struct NativeVolume3DInteraction {
    struct Handlers {
        var begin: @MainActor () -> Void
        var pan: @MainActor (CGSize) -> Bool
        var twoFingerPan: @MainActor (CGSize) -> Bool
        var pinch: @MainActor (CGFloat) -> Bool
        var rotation: @MainActor (CGFloat) -> Bool
        var frame: @MainActor () -> Void
        var end: @MainActor () -> Void
        var diagnostics: @MainActor () -> String
    }

    let handlers: Handlers
    let preferredFramesPerSecond: Int

    public init(viewport: VolumeViewport3D,
                interactionMode: NativeVolume3DInteractionMode = .orbit,
                preferredFramesPerSecond: Int = 30) {
        self.handlers = Handlers(
            begin: {
                viewport.beginNativeCameraInteraction()
            },
            pan: { delta in
                switch interactionMode {
                case .orbit:
                    return viewport.applyNativeOrbitDelta(delta)
                case .pan:
                    return viewport.applyNativePanDelta(delta)
                }
            },
            twoFingerPan: { delta in
                viewport.applyNativePanDelta(delta)
            },
            pinch: { scale in
                viewport.applyNativeZoomScale(Float(scale))
            },
            rotation: { radians in
                viewport.applyNativeRollRadians(Float(radians))
            },
            frame: {
                viewport.flushNativeCameraInteractionRender()
            },
            end: {
                viewport.flushNativeCameraInteractionRender()
                viewport.endNativeCameraInteraction()
            },
            diagnostics: {
                viewport.nativeCameraInteractionDiagnostics()
            }
        )
        self.preferredFramesPerSecond = max(preferredFramesPerSecond, 1)
    }

    @_spi(Testing)
    public init(preferredFramesPerSecond: Int = 30,
                begin: @escaping @MainActor () -> Void = {},
                pan: @escaping @MainActor (CGSize) -> Bool = { _ in false },
                twoFingerPan: @escaping @MainActor (CGSize) -> Bool = { _ in false },
                pinch: @escaping @MainActor (CGFloat) -> Bool = { _ in false },
                rotation: @escaping @MainActor (CGFloat) -> Bool = { _ in false },
                frame: @escaping @MainActor () -> Void = {},
                end: @escaping @MainActor () -> Void = {},
                diagnostics: @escaping @MainActor () -> String = { "" }) {
        self.handlers = Handlers(begin: begin,
                                 pan: pan,
                                 twoFingerPan: twoFingerPan,
                                 pinch: pinch,
                                 rotation: rotation,
                                 frame: frame,
                                 end: end,
                                 diagnostics: diagnostics)
        self.preferredFramesPerSecond = max(preferredFramesPerSecond, 1)
    }

    init(controller: ClinicalViewportGridController,
         preferredFramesPerSecond: Int = 30) {
        self.handlers = Handlers(
            begin: {
                controller.beginNativeVolumeCameraInteraction()
            },
            pan: { delta in
                controller.rotateVolumeCameraInteractively(screenDelta: delta)
            },
            twoFingerPan: { delta in
                controller.rotateVolumeCameraInteractively(screenDelta: delta)
            },
            pinch: { scale in
                controller.zoomVolumeCameraInteractively(scale: Float(scale))
            },
            rotation: { radians in
                controller.tiltVolumeCameraInteractively(roll: Float(radians), pitch: 0)
            },
            frame: {
                controller.flushVolumeCameraInteractionRender()
            },
            end: {
                controller.flushVolumeCameraInteractionRender()
                controller.endNativeVolumeCameraInteraction()
            },
            diagnostics: {
                controller.nativeVolumeCameraInteractionDiagnostics()
            }
        )
        self.preferredFramesPerSecond = max(preferredFramesPerSecond, 1)
    }
}

@MainActor
public final class NativeVolume3DInteractionInstaller: NSObject, UIGestureRecognizerDelegate {
    private var interaction: NativeVolume3DInteraction?
    private weak var installedView: UIView?
    private var primaryPanRecognizer: UIPanGestureRecognizer?
    private var twoFingerPanRecognizer: UIPanGestureRecognizer?
    private var pinchRecognizer: UIPinchGestureRecognizer?
    private var rotationRecognizer: UIRotationGestureRecognizer?
    private var touchProbeRecognizer: NativeVolume3DTouchProbeRecognizer?
    private var activeGestureCount = 0
    private var needsFrame = false
    private var displayLink: CADisplayLink?
    private let logger = Logger(category: "NativeVolume3DInteraction")
    private weak var hitTestView: UIView?
    private var gestureSequence: UInt64 = 0
    private var frameRequestCount: UInt64 = 0
    private var frameFlushCount: UInt64 = 0
    private var displayLinkTickCount: UInt64 = 0
    private var lastFrameRequestAt: CFAbsoluteTime?
    private var gestureSessionStartedAt: CFAbsoluteTime?

    deinit {
        displayLink?.invalidate()
        if let primaryPanRecognizer, let installedView {
            installedView.removeGestureRecognizer(primaryPanRecognizer)
        }
        if let twoFingerPanRecognizer, let installedView {
            installedView.removeGestureRecognizer(twoFingerPanRecognizer)
        }
        if let pinchRecognizer, let installedView {
            installedView.removeGestureRecognizer(pinchRecognizer)
        }
        if let rotationRecognizer, let installedView {
            installedView.removeGestureRecognizer(rotationRecognizer)
        }
        if let touchProbeRecognizer, let installedView {
            installedView.removeGestureRecognizer(touchProbeRecognizer)
        }
    }

    func install(on target: UIView, interaction: NativeVolume3DInteraction?) {
        guard let interaction else {
            uninstall()
            return
        }

        let gestureTarget = target
        hitTestView = target

        guard installedView !== gestureTarget else {
            self.interaction = interaction
            displayLink?.preferredFramesPerSecond = interaction.preferredFramesPerSecond
            logInstallState("native.install.update", target: target, gestureTarget: gestureTarget)
            return
        }
        uninstall()
        self.interaction = interaction
        displayLink?.preferredFramesPerSecond = interaction.preferredFramesPerSecond
        hitTestView = target

        target.isUserInteractionEnabled = true
        gestureTarget.isUserInteractionEnabled = true
        gestureTarget.isMultipleTouchEnabled = true

        let primaryPan = UIPanGestureRecognizer(target: self,
                                                action: #selector(handlePrimaryPan(_:)))
        primaryPan.minimumNumberOfTouches = 1
        primaryPan.maximumNumberOfTouches = 1
        primaryPan.cancelsTouchesInView = false
        primaryPan.delaysTouchesBegan = false
        primaryPan.delaysTouchesEnded = false
        primaryPan.requiresExclusiveTouchType = false
        primaryPan.delegate = self
        gestureTarget.addGestureRecognizer(primaryPan)

        let twoFingerPan = UIPanGestureRecognizer(target: self,
                                                  action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.cancelsTouchesInView = false
        twoFingerPan.delaysTouchesBegan = false
        twoFingerPan.delaysTouchesEnded = false
        twoFingerPan.requiresExclusiveTouchType = false
        twoFingerPan.delegate = self
        gestureTarget.addGestureRecognizer(twoFingerPan)

        let pinch = UIPinchGestureRecognizer(target: self,
                                             action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        pinch.delegate = self
        gestureTarget.addGestureRecognizer(pinch)

        let rotation = UIRotationGestureRecognizer(target: self,
                                                   action: #selector(handleRotation(_:)))
        rotation.cancelsTouchesInView = false
        rotation.delaysTouchesBegan = false
        rotation.delaysTouchesEnded = false
        rotation.delegate = self
        gestureTarget.addGestureRecognizer(rotation)

        let touchProbe = NativeVolume3DTouchProbeRecognizer()
        touchProbe.cancelsTouchesInView = false
        touchProbe.delaysTouchesBegan = false
        touchProbe.delaysTouchesEnded = false
        touchProbe.requiresExclusiveTouchType = false
        touchProbe.delegate = self
        gestureTarget.addGestureRecognizer(touchProbe)

        installedView = gestureTarget
        primaryPanRecognizer = primaryPan
        twoFingerPanRecognizer = twoFingerPan
        pinchRecognizer = pinch
        rotationRecognizer = rotation
        touchProbeRecognizer = touchProbe
        logInstallState("native.install", target: target, gestureTarget: gestureTarget)
    }

    @_spi(Testing)
    public func installForTesting(on target: UIView, interaction: NativeVolume3DInteraction?) {
        install(on: target, interaction: interaction)
    }

    @_spi(Testing)
    public var installedViewForTesting: UIView? {
        installedView
    }

    @_spi(Testing)
    public var needsFrameForTesting: Bool {
        needsFrame
    }

    @_spi(Testing)
    public var frameFlushCountForTesting: Int {
        Int(frameFlushCount)
    }

    @_spi(Testing)
    public func beginGestureForTesting() {
        beginGesture()
    }

    @_spi(Testing)
    public func endGestureForTesting() {
        endGesture()
    }

    @_spi(Testing)
    public func flushFrameForTesting(reason: String = "test") {
        flushFrameIfNeeded(reason: reason)
    }

    @_spi(Testing)
    public func applyPanDeltaForTesting(_ delta: CGSize) {
        applyPrimaryPanDelta(delta)
    }

    @_spi(Testing)
    public func applyTwoFingerPanDeltaForTesting(_ delta: CGSize) {
        applyTwoFingerPanDelta(delta)
    }

    @_spi(Testing)
    public func applyPinchScaleForTesting(_ scale: CGFloat) {
        applyPinchScale(scale)
    }

    @_spi(Testing)
    public func applyRotationRadiansForTesting(_ radians: CGFloat) {
        _ = applyRotationRadians(radians)
    }

    @objc private func handlePrimaryPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            logAlways("[MTK3DInteraction] native.rotate.begin touches=1 view=\(Self.describe(recognizer.view))")
            beginGesture()
            recognizer.setTranslation(.zero, in: recognizer.view)
        case .changed:
            applyPanTranslation(from: recognizer,
                                eventName: "native.rotate.delta",
                                apply: applyPrimaryPanDelta(_:))
        case .ended, .cancelled, .failed:
            applyPanTranslation(from: recognizer,
                                eventName: "native.rotate.delta",
                                apply: applyPrimaryPanDelta(_:))
            logAlways("[MTK3DInteraction] native.rotate.end state=\(recognizer.state.rawValue) touches=1")
            recognizer.setTranslation(.zero, in: recognizer.view)
            endGesture()
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            logAlways("[MTK3DInteraction] native.pan.begin touches=2 view=\(Self.describe(recognizer.view))")
            beginGesture()
            recognizer.setTranslation(.zero, in: recognizer.view)
        case .changed:
            applyPanTranslation(from: recognizer,
                                eventName: "native.pan.delta",
                                apply: applyTwoFingerPanDelta(_:))
        case .ended, .cancelled, .failed:
            applyPanTranslation(from: recognizer,
                                eventName: "native.pan.delta",
                                apply: applyTwoFingerPanDelta(_:))
            logAlways("[MTK3DInteraction] native.pan.end touches=2 state=\(recognizer.state.rawValue)")
            recognizer.setTranslation(.zero, in: recognizer.view)
            endGesture()
        default:
            break
        }
    }

    private func applyPanTranslation(from recognizer: UIPanGestureRecognizer,
                                     eventName: String,
                                     apply: (CGSize) -> Void) {
        let translation = recognizer.translation(in: recognizer.view)
        guard abs(translation.x) >= 0.5 || abs(translation.y) >= 0.5 else { return }
        let delta = CGSize(width: translation.x, height: translation.y)
        logAlways(String(format: "[MTK3DInteraction] %@ dx=%.2f dy=%.2f active=%d needsFrame=%@",
                         eventName,
                         delta.width,
                         delta.height,
                         activeGestureCount,
                         needsFrame ? "true" : "false"))
        apply(delta)
        recognizer.setTranslation(.zero, in: recognizer.view)
    }

    private func applyPrimaryPanDelta(_ delta: CGSize) {
        logAlways("[MTK3DInteraction] native.rotate.delta.apply.before sequence=\(gestureSequence) \(diagnostics())")
        guard interaction?.handlers.pan(delta) == true else { return }
        logAlways("[MTK3DInteraction] native.rotate.delta.apply.after sequence=\(gestureSequence) \(diagnostics())")
        requestFrame(reason: "primaryPan")
    }

    private func applyTwoFingerPanDelta(_ delta: CGSize) {
        logAlways("[MTK3DInteraction] native.pan.delta.apply.before sequence=\(gestureSequence) \(diagnostics())")
        guard interaction?.handlers.twoFingerPan(delta) == true else { return }
        logAlways("[MTK3DInteraction] native.pan.delta.apply.after sequence=\(gestureSequence) \(diagnostics())")
        requestFrame(reason: "twoFingerPan")
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            logAlways("[MTK3DInteraction] native.pinch.begin")
            beginGesture()
            recognizer.scale = 1
        case .changed:
            if applyPinchScale(recognizer.scale) {
                recognizer.scale = 1
            }
        case .ended, .cancelled, .failed:
            logAlways("[MTK3DInteraction] native.pinch.end state=\(recognizer.state.rawValue)")
            recognizer.scale = 1
            endGesture()
        default:
            break
        }
    }

    @discardableResult
    private func applyPinchScale(_ scale: CGFloat) -> Bool {
        guard scale.isFinite, abs(scale - 1) >= 0.005 else { return false }
        logAlways(String(format: "[MTK3DInteraction] native.pinch.scale %.4f active=%d needsFrame=%@",
                         scale,
                         activeGestureCount,
                         needsFrame ? "true" : "false"))
        guard interaction?.handlers.pinch(scale) == true else { return true }
        requestFrame(reason: "pinch")
        return true
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            logAlways("[MTK3DInteraction] native.roll.begin touches=2")
            beginGesture()
            recognizer.rotation = 0
        case .changed:
            if applyRotationRadians(recognizer.rotation) {
                recognizer.rotation = 0
            }
        case .ended, .cancelled, .failed:
            if applyRotationRadians(recognizer.rotation) {
                recognizer.rotation = 0
            }
            logAlways("[MTK3DInteraction] native.roll.end state=\(recognizer.state.rawValue)")
            endGesture()
        default:
            break
        }
    }

    @discardableResult
    private func applyRotationRadians(_ radians: CGFloat) -> Bool {
        guard radians.isFinite, abs(radians) >= 0.002 else { return false }
        let appliedRadians = -radians
        logAlways(String(format: "[MTK3DInteraction] native.roll.radians %.4f active=%d needsFrame=%@",
                         appliedRadians,
                         activeGestureCount,
                         needsFrame ? "true" : "false"))
        guard interaction?.handlers.rotation(appliedRadians) == true else { return true }
        requestFrame(reason: "twoFingerRoll")
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldReceive touch: UITouch) -> Bool {
        guard let hitTestView else {
            logAlways("[MTK3DInteraction] native.touch.receive allowed=true reason=no-hit-test-view")
            return true
        }
        let point = touch.location(in: hitTestView)
        guard hitTestView.bounds.contains(point) else {
            logAlways(String(format: "[MTK3DInteraction] native.touch.receive allowed=false reason=outside point=%.1f,%.1f bounds=%@ touchView=%@",
                             point.x,
                             point.y,
                             Self.describe(hitTestView.bounds),
                             Self.describe(touch.view)))
            return false
        }
        let interactiveControlTouch = Self.isInteractiveControlTouch(touch.view,
                                                                     stoppingAt: gestureRecognizer.view)
        logAlways(String(format: "[MTK3DInteraction] native.touch.receive allowed=%@ reason=%@ point=%.1f,%.1f bounds=%@ touchView=%@",
                         interactiveControlTouch ? "false" : "true",
                         interactiveControlTouch ? "interactive-control" : "surface-region",
                         point.x,
                         point.y,
                         Self.describe(hitTestView.bounds),
                         Self.describe(touch.view)))
        return !interactiveControlTouch
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func beginGesture() {
        let activeBefore = activeGestureCount
        activeGestureCount += 1
        logAlways("[MTK3DInteraction] native.gesture.begin activeBefore=\(activeBefore) activeAfter=\(activeGestureCount) sequence=\(gestureSequence)")
        guard activeGestureCount == 1 else { return }
        gestureSequence &+= 1
        gestureSessionStartedAt = CFAbsoluteTimeGetCurrent()
        frameRequestCount = 0
        frameFlushCount = 0
        displayLinkTickCount = 0
        logAlways("[MTK3DInteraction] native.gesture.session.start sequence=\(gestureSequence) view=\(Self.describe(installedView)) windowReady=\(installedView?.window != nil) bounds=\(Self.describe(installedView?.bounds ?? .zero)) \(diagnostics())")
        interaction?.handlers.begin()
        startDisplayLink()
    }

    private func endGesture() {
        let activeBefore = activeGestureCount
        activeGestureCount = max(activeGestureCount - 1, 0)
        logAlways("[MTK3DInteraction] native.gesture.end activeBefore=\(activeBefore) activeAfter=\(activeGestureCount) sequence=\(gestureSequence) needsFrame=\(needsFrame)")
        guard activeGestureCount == 0 else { return }
        flushFrameIfNeeded(reason: "end")
        stopDisplayLink()
        interaction?.handlers.end()
        let durationMilliseconds = gestureSessionStartedAt.map { max(0, (CFAbsoluteTimeGetCurrent() - $0) * 1000.0) }
        logAlways("[MTK3DInteraction] native.gesture.session.end sequence=\(gestureSequence) requests=\(frameRequestCount) flushes=\(frameFlushCount) displayTicks=\(displayLinkTickCount) durationMs=\(Self.formatMilliseconds(durationMilliseconds)) \(diagnostics())")
        gestureSessionStartedAt = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self,
                                 selector: #selector(displayLinkTick(_:)))
        link.preferredFramesPerSecond = interaction?.preferredFramesPerSecond ?? 30
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkTickCount = 0
        logAlways("[MTK3DInteraction] native.displayLink.start fps=\(link.preferredFramesPerSecond) sequence=\(gestureSequence) active=\(activeGestureCount)")
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        needsFrame = false
        logAlways("[MTK3DInteraction] native.displayLink.stop sequence=\(gestureSequence) ticks=\(displayLinkTickCount) requests=\(frameRequestCount) flushes=\(frameFlushCount)")
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        displayLinkTickCount &+= 1
        if needsFrame || displayLinkTickCount % 10 == 0 {
            logDebug("[MTK3DInteraction] native.displayLink.tick sequence=\(gestureSequence) tick=\(displayLinkTickCount) needsFrame=\(needsFrame) active=\(activeGestureCount)")
        }
        flushFrameIfNeeded(reason: "displayLink")
    }

    func renderAfterViewportLifecycleEvent(_ reason: String) {
        guard interaction != nil else { return }
        requestFrame(reason: reason)
    }

    private func requestFrame(reason: String) {
        let requestNumber = frameRequestCount &+ 1
        frameRequestCount = requestNumber
        let now = CFAbsoluteTimeGetCurrent()
        let previousRequestAge = lastFrameRequestAt.map { max(0, (now - $0) * 1000.0) }
        lastFrameRequestAt = now
        logAlways("[MTK3DInteraction] native.frame.request sequence=\(gestureSequence) request=\(requestNumber) reason=\(reason) needsBefore=\(needsFrame) active=\(activeGestureCount) displayLink=\(displayLink != nil) previousRequestAgeMs=\(Self.formatMilliseconds(previousRequestAge)) view=\(Self.describe(installedView)) windowReady=\(installedView?.window != nil) bounds=\(Self.describe(installedView?.bounds ?? .zero))")
        needsFrame = true
        if shouldFlushImmediately {
            flushFrameIfNeeded(reason: reason)
        }
    }

    private var shouldFlushImmediately: Bool {
        activeGestureCount == 0 || frameFlushCount == 0
    }

    private func flushFrameIfNeeded(reason: String) {
        guard needsFrame else { return }
        needsFrame = false
        frameFlushCount &+= 1
        let requestAge = lastFrameRequestAt.map { max(0, (CFAbsoluteTimeGetCurrent() - $0) * 1000.0) }
        logAlways("[MTK3DInteraction] native.frame.flush sequence=\(gestureSequence) flush=\(frameFlushCount) reason=\(reason) requestAgeMs=\(Self.formatMilliseconds(requestAge)) active=\(activeGestureCount)")
        interaction?.handlers.frame()
    }

    private func uninstall() {
        displayLink?.invalidate()
        displayLink = nil
        activeGestureCount = 0
        needsFrame = false
        interaction = nil
        gestureSequence = 0
        frameRequestCount = 0
        frameFlushCount = 0
        displayLinkTickCount = 0
        lastFrameRequestAt = nil
        gestureSessionStartedAt = nil
        if let primaryPanRecognizer, let installedView {
            installedView.removeGestureRecognizer(primaryPanRecognizer)
        }
        if let twoFingerPanRecognizer, let installedView {
            installedView.removeGestureRecognizer(twoFingerPanRecognizer)
        }
        if let pinchRecognizer, let installedView {
            installedView.removeGestureRecognizer(pinchRecognizer)
        }
        if let rotationRecognizer, let installedView {
            installedView.removeGestureRecognizer(rotationRecognizer)
        }
        if let touchProbeRecognizer, let installedView {
            installedView.removeGestureRecognizer(touchProbeRecognizer)
        }
        primaryPanRecognizer = nil
        twoFingerPanRecognizer = nil
        pinchRecognizer = nil
        rotationRecognizer = nil
        touchProbeRecognizer = nil
        installedView = nil
        hitTestView = nil
    }

    private func logInstall(_ message: @autoclosure () -> String) {
#if DEBUG
        logger.info(message())
#else
        logDebug(message())
#endif
    }

    private func logInstallState(_ event: String, target: UIView, gestureTarget: UIView) {
        let windowFrame = target.convert(target.bounds, to: target.window)
        logInstall("[MTK3DInteraction] \(event) target=\(ObjectIdentifier(target)) type=\(String(describing: type(of: target))) gestureTarget=\(ObjectIdentifier(gestureTarget)) gestureType=\(String(describing: type(of: gestureTarget))) windowReady=\(target.window != nil) bounds=\(Self.describe(target.bounds)) frame=\(Self.describe(target.frame)) windowFrame=\(Self.describe(windowFrame)) recognizers=\(gestureTarget.gestureRecognizers?.count ?? 0)")
    }

    private func logDebug(_ message: @autoclosure () -> String) {
        guard Logger.interactionLoggingEnabled else { return }
        logger.debug(message())
    }

    private func logAlways(_ message: @autoclosure () -> String) {
        logDebug(message())
    }

    private func diagnostics() -> String {
        interaction?.handlers.diagnostics() ?? ""
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "{{%.1f,%.1f},{%.1f,%.1f}}",
               rect.origin.x,
               rect.origin.y,
               rect.size.width,
               rect.size.height)
    }

    private static func describe(_ view: UIView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    private static func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.3f", value)
    }

    private static func isInteractiveControlTouch(_ view: UIView?, stoppingAt stopView: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is UIControl || candidate is UIScrollView {
                return true
            }
            if candidate === stopView {
                return false
            }
            current = candidate.superview
        }
        return false
    }
}

@MainActor
private final class NativeVolume3DTouchProbeRecognizer: UIGestureRecognizer {
    private let logger = Logger(category: "NativeVolume3DTouchProbe")
    private var sequence: UInt64 = 0
    private var moveCount: UInt64 = 0
    private var beganAt: CFAbsoluteTime?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        sequence &+= 1
        moveCount = 0
        beganAt = CFAbsoluteTimeGetCurrent()
        logger.info("[MTK3DInteraction] native.touch.began sequence=\(sequence) touches=\(touches.count) \(describeTouches(touches)) view=\(describe(view)) windowReady=\(view?.window != nil)")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        moveCount &+= 1
        logger.info("[MTK3DInteraction] native.touch.moved sequence=\(sequence) move=\(moveCount) touches=\(touches.count) ageMs=\(formatAge()) \(describeTouches(touches))")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        logger.info("[MTK3DInteraction] native.touch.ended sequence=\(sequence) moves=\(moveCount) touches=\(touches.count) ageMs=\(formatAge()) \(describeTouches(touches))")
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        logger.info("[MTK3DInteraction] native.touch.cancelled sequence=\(sequence) moves=\(moveCount) touches=\(touches.count) ageMs=\(formatAge()) \(describeTouches(touches))")
        state = .failed
    }

    override func reset() {
        moveCount = 0
        beganAt = nil
    }

    private func describeTouches(_ touches: Set<UITouch>) -> String {
        guard let view else { return "points=[]" }
        let points = touches.map { touch -> String in
            let point = touch.location(in: view)
            let previous = touch.previousLocation(in: view)
            return String(format: "(%.1f,%.1f prev=%.1f,%.1f phase=%ld)",
                          point.x,
                          point.y,
                          previous.x,
                          previous.y,
                          touch.phase.rawValue)
        }
        .joined(separator: ",")
        return "points=[\(points)]"
    }

    private func describe(_ view: UIView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    private func formatAge() -> String {
        guard let beganAt else { return "nil" }
        return String(format: "%.3f", max(0, (CFAbsoluteTimeGetCurrent() - beganAt) * 1000.0))
    }
}

/// Compatibility wrapper for older callers. New MTKUI code should install
/// ``NativeVolume3DInteraction`` directly through ``MetalViewportContainer``.
@MainActor
public struct NativeVolume3DInteractionOverlay: UIViewRepresentable {
    private let interaction: NativeVolume3DInteraction

    public init(viewport: VolumeViewport3D,
                interactionMode: NativeVolume3DInteractionMode = .orbit,
                preferredFramesPerSecond: Int = 30) {
        self.interaction = NativeVolume3DInteraction(viewport: viewport,
                                                     interactionMode: interactionMode,
                                                     preferredFramesPerSecond: preferredFramesPerSecond)
    }

    init(controller: ClinicalViewportGridController,
         preferredFramesPerSecond: Int = 30) {
        self.interaction = NativeVolume3DInteraction(controller: controller,
                                                     preferredFramesPerSecond: preferredFramesPerSecond)
    }

    public func makeCoordinator() -> NativeVolume3DInteractionInstaller {
        NativeVolume3DInteractionInstaller()
    }

    public func makeUIView(context: Context) -> InteractionInstallerView {
        let view = InteractionInstallerView()
        view.configure(installer: context.coordinator,
                       interaction: interaction)
        return view
    }

    public func updateUIView(_ uiView: InteractionInstallerView, context: Context) {
        uiView.configure(installer: context.coordinator,
                         interaction: interaction)
    }

    public final class InteractionInstallerView: UIView {
        private weak var installer: NativeVolume3DInteractionInstaller?
        private var interaction: NativeVolume3DInteraction?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(installer: NativeVolume3DInteractionInstaller,
                       interaction: NativeVolume3DInteraction) {
            self.installer = installer
            self.interaction = interaction
            installIfPossible()
        }

        public override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installIfPossible()
        }

        private func installIfPossible() {
            guard let installer, let interaction, let target = superview else { return }
            installer.install(on: target, interaction: interaction)
        }
    }
}
#endif
