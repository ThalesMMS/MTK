//
//  NativeVolume3DInteraction.swift
//  MTKUI
//
//  Platform-neutral camera-interaction handler bundle for the 3D volume
//  viewport. Installed by NativeVolume3DInteractionOverlay (UIKit) and
//  NativeVolume3DInteractionLayer (AppKit).
//

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import CoreGraphics
import Foundation

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
                case .tilt:
                    return viewport.applyNativeTiltDelta(delta)
                case .pan:
                    return viewport.applyNativePanDelta(delta)
                case .transferFunction:
                    Task { @MainActor in
                        await viewport.adjustTransferFunctionShift(screenDelta: SIMD2<Float>(Float(delta.width), Float(delta.height)))
                    }
                    return true
                case .crop:
                    return false
                case .brush:
                    return false
                }
            },
            twoFingerPan: { delta in
                guard interactionMode.allowsNativeCameraGestures else { return false }
                return viewport.applyNativePanDelta(delta)
            },
            pinch: { scale in
                guard interactionMode.allowsNativeCameraGestures else { return false }
                return viewport.applyNativeZoomScale(Float(scale))
            },
            rotation: { radians in
                guard interactionMode.allowsNativeCameraGestures else { return false }
                return viewport.applyNativeRollRadians(Float(radians))
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
         interactionMode: NativeVolume3DInteractionMode = .orbit,
         preferredFramesPerSecond: Int = 30) {
        self.handlers = Handlers(
            begin: {
                controller.beginNativeVolumeCameraInteraction()
            },
            pan: { delta in
                switch interactionMode {
                case .orbit:
                    return controller.rotateVolumeCameraInteractively(screenDelta: delta)
                case .tilt:
                    let scale: Float = 0.01
                    return controller.tiltVolumeCameraInteractively(
                        roll: -Float(delta.width) * scale,
                        pitch: -Float(delta.height) * scale
                    )
                case .pan:
                    return controller.panVolumeCameraInteractively(screenDelta: delta)
                case .transferFunction:
                    Task { @MainActor in
                        await controller.adjustTransferFunctionShift(screenDelta: delta)
                    }
                    return true
                case .crop:
                    return false
                case .brush:
                    return false
                }
            },
            twoFingerPan: { delta in
                guard interactionMode.allowsNativeCameraGestures else { return false }
                return controller.panVolumeCameraInteractively(screenDelta: delta)
            },
            pinch: { scale in
                guard interactionMode.allowsNativeCameraGestures else { return false }
                return controller.zoomVolumeCameraInteractively(scale: Float(scale))
            },
            rotation: { radians in
                guard interactionMode.allowsNativeCameraGestures else { return false }
                return controller.tiltVolumeCameraInteractively(roll: Float(radians), pitch: 0)
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
#endif
