//
//  NativeVolume3DInteractionLayer_macOS.swift
//  MTKUI
//
//  AppKit gesture layer for the 3D volume viewport: drives the same
//  NativeVolume3DInteraction handlers the UIKit installer uses, mapping
//  mouse drag to the active interaction mode (orbit/tilt/pan/transfer
//  function), shift-drag to camera pan, trackpad magnify and scroll wheel
//  to zoom, and trackpad rotate to roll.
//

#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI

@MainActor
public struct NativeVolume3DInteractionLayer: NSViewRepresentable {
    private let interaction: NativeVolume3DInteraction

    public init(interaction: NativeVolume3DInteraction) {
        self.interaction = interaction
    }

    public func makeNSView(context: Context) -> Volume3DInteractionNSView {
        let view = Volume3DInteractionNSView(frame: .zero)
        view.interaction = interaction
        return view
    }

    public func updateNSView(_ nsView: Volume3DInteractionNSView, context: Context) {
        nsView.interaction = interaction
    }
}

@MainActor
public final class Volume3DInteractionNSView: NSView {
    var interaction: NativeVolume3DInteraction?

    private var activeGestureCount = 0
    private var scrollZoomIdleTask: Task<Void, Never>?
    private static let scrollZoomIdleNanoseconds: UInt64 = 150_000_000
    /// Zoom sensitivity per scroll point (precise) or per scroll line.
    private static let preciseScrollZoomFactor: CGFloat = 0.004
    private static let lineScrollZoomFactor: CGFloat = 0.05

    public override var acceptsFirstResponder: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse drag

    public override func mouseDown(with event: NSEvent) {
        beginGesture()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard activeGestureCount > 0 else { return }
        let delta = CGSize(width: event.deltaX, height: event.deltaY)
        guard abs(delta.width) >= 0.1 || abs(delta.height) >= 0.1 else { return }
        let applied: Bool
        if event.modifierFlags.contains(.shift) {
            applied = interaction?.handlers.twoFingerPan(delta) == true
        } else {
            applied = interaction?.handlers.pan(delta) == true
        }
        if applied {
            interaction?.handlers.frame()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        endGesture()
    }

    // MARK: - Trackpad magnify / rotate

    public override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            beginGesture()
        case .changed:
            applyZoomScale(1 + event.magnification)
        case .ended, .cancelled:
            applyZoomScale(1 + event.magnification)
            endGesture()
        default:
            break
        }
    }

    public override func rotate(with event: NSEvent) {
        switch event.phase {
        case .began:
            beginGesture()
            applyRollRotation(event)
        case .changed:
            applyRollRotation(event)
        case .ended, .cancelled:
            applyRollRotation(event)
            endGesture()
        default:
            break
        }
    }

    private func applyRollRotation(_ event: NSEvent) {
        // AppKit reports degrees, counterclockwise-positive — already the
        // orientation the roll handler expects (the UIKit path negates the
        // clockwise-positive recognizer value to match).
        let radians = CGFloat(event.rotation) * .pi / 180
        guard radians.isFinite, abs(radians) >= 0.002 else { return }
        if interaction?.handlers.rotation(radians) == true {
            interaction?.handlers.frame()
        }
    }

    // MARK: - Scroll wheel zoom

    public override func scrollWheel(with event: NSEvent) {
        let factor = event.hasPreciseScrollingDeltas
            ? Self.preciseScrollZoomFactor
            : Self.lineScrollZoomFactor
        let scale = exp(event.scrollingDeltaY * factor)
        guard scale.isFinite, abs(scale - 1) >= 0.001 else { return }

        if scrollZoomIdleTask == nil {
            beginGesture()
        } else {
            scrollZoomIdleTask?.cancel()
        }
        applyZoomScale(scale)
        scrollZoomIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.scrollZoomIdleNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.scrollZoomIdleTask = nil
            self.endGesture()
        }
    }

    // MARK: - Helpers

    private func applyZoomScale(_ scale: CGFloat) {
        guard scale.isFinite, abs(scale - 1) >= 0.001 else { return }
        if interaction?.handlers.pinch(scale) == true {
            interaction?.handlers.frame()
        }
    }

    private func beginGesture() {
        activeGestureCount += 1
        guard activeGestureCount == 1 else { return }
        interaction?.handlers.begin()
    }

    private func endGesture() {
        activeGestureCount = max(activeGestureCount - 1, 0)
        guard activeGestureCount == 0 else { return }
        interaction?.handlers.end()
    }
}
#endif
