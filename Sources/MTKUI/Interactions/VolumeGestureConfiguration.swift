//  VolumeGestureConfiguration.swift
//  MTK
//  Shared gesture configuration and state mapping for volumetric interactions.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Combine)
import Combine
#endif
import simd

/// Configuration toggles describing which gesture capabilities are active.
public struct VolumeGestureConfiguration: Sendable, Equatable {
    public var allowsTranslation: Bool
    public var allowsZoom: Bool
    public var allowsRotation: Bool
    public var allowsWindowLevel: Bool
    public var allowsSlabThickness: Bool
    public var translationAxis: VolumeGestureAxis?

    public init(allowsTranslation: Bool = true,
                allowsZoom: Bool = true,
                allowsRotation: Bool = true,
                allowsWindowLevel: Bool = true,
                allowsSlabThickness: Bool = true,
                translationAxis: VolumeGestureAxis? = nil) {
        self.allowsTranslation = allowsTranslation
        self.allowsZoom = allowsZoom
        self.allowsRotation = allowsRotation
        self.allowsWindowLevel = allowsWindowLevel
        self.allowsSlabThickness = allowsSlabThickness
        self.translationAxis = translationAxis
    }

    public static let `default` = VolumeGestureConfiguration()
}

public enum VolumeGestureAxis: String, CaseIterable, Codable, Sendable {
    case axial
    case coronal
    case sagittal
    case volume
}

public struct WindowLevelShift: Sendable, Equatable {
    public var window: Double
    public var level: Double

    public init(window: Double, level: Double) {
        self.window = window
        self.level = level
    }

    public static let zero = WindowLevelShift(window: .zero, level: .zero)
}

public enum VolumeGestureEvent: Sendable, Equatable {
    case translate(axis: VolumeGestureAxis, delta: CGSize)
    case zoom(factor: CGFloat)
    case rotate(axis: VolumeGestureAxis, radians: CGFloat)
    case adjustWindow(WindowLevelShift)
    case adjustSlab(thickness: Double)
    case reset
}

public struct VolumeGestureContext: Sendable {
    public var onTranslate: @Sendable (VolumeGestureAxis, CGSize) -> Void
    public var onZoom: @Sendable (CGFloat) -> Void
    public var onRotate: @Sendable (VolumeGestureAxis, CGFloat) -> Void
    public var onWindowLevel: @Sendable (WindowLevelShift) -> Void
    public var onSlabThickness: @Sendable (Double) -> Void
    public var onReset: @Sendable () -> Void

    public init(onTranslate: @escaping @Sendable (VolumeGestureAxis, CGSize) -> Void = { _, _ in },
                onZoom: @escaping @Sendable (CGFloat) -> Void = { _ in },
                onRotate: @escaping @Sendable (VolumeGestureAxis, CGFloat) -> Void = { _, _ in },
                onWindowLevel: @escaping @Sendable (WindowLevelShift) -> Void = { _ in },
                onSlabThickness: @escaping @Sendable (Double) -> Void = { _ in },
                onReset: @escaping @Sendable () -> Void = {}) {
        self.onTranslate = onTranslate
        self.onZoom = onZoom
        self.onRotate = onRotate
        self.onWindowLevel = onWindowLevel
        self.onSlabThickness = onSlabThickness
        self.onReset = onReset
    }

    public static let passthrough = VolumeGestureContext()
}

#if canImport(SwiftUI)
@MainActor
public final class VolumeGestureState: ObservableObject {
    @Published public private(set) var lastEvent: VolumeGestureEvent?
    @Published public private(set) var windowLevelShift: WindowLevelShift
    @Published public private(set) var slabThickness: Double

    public init(windowLevelShift: WindowLevelShift = .zero, slabThickness: Double = .zero) {
        self.windowLevelShift = windowLevelShift
        self.slabThickness = slabThickness
    }

    public func ingest(_ event: VolumeGestureEvent) {
        lastEvent = event
        switch event {
        case .adjustWindow(let shift):
            windowLevelShift = shift
        case .adjustSlab(let thickness):
            slabThickness = thickness
        default:
            break
        }
    }

    public func makeContext(merging context: VolumeGestureContext = .passthrough) -> VolumeGestureContext {
        VolumeGestureContext(
            onTranslate: { [weak self] axis, delta in
                Task { @MainActor in self?.ingest(.translate(axis: axis, delta: delta)) }
                context.onTranslate(axis, delta)
            },
            onZoom: { [weak self] factor in
                Task { @MainActor in self?.ingest(.zoom(factor: factor)) }
                context.onZoom(factor)
            },
            onRotate: { [weak self] axis, radians in
                Task { @MainActor in self?.ingest(.rotate(axis: axis, radians: radians)) }
                context.onRotate(axis, radians)
            },
            onWindowLevel: { [weak self] shift in
                Task { @MainActor in self?.ingest(.adjustWindow(shift)) }
                context.onWindowLevel(shift)
            },
            onSlabThickness: { [weak self] thickness in
                Task { @MainActor in self?.ingest(.adjustSlab(thickness: thickness)) }
                context.onSlabThickness(thickness)
            },
            onReset: { [weak self] in
                Task { @MainActor in self?.ingest(.reset) }
                context.onReset()
            }
        )
    }
}
#endif

#if canImport(SwiftUI) && os(iOS)
 
extension VolumetricSceneController {
    public func gestureContext(using state: VolumeGestureState) -> VolumeGestureContext {
        let handler = VolumeGestureContext(
            onTranslate: { axis, delta in
                Task { [weak self] in
                    guard let self else { return }
                    if axis == .volume {
                        let screenDelta = SIMD2<Float>(Float(delta.width), Float(delta.height))
                        await self.rotateCamera(screenDelta: screenDelta)
                        return
                    }
                    guard let controllerAxis = VolumetricSceneController.Axis(axis) else { return }
                    let normalized = Float(delta.height / 512)
                    await self.translate(axis: controllerAxis, deltaNormalized: normalized)
                }
            },
            onZoom: { factor in
                Task { [weak self] in
                    guard let self else { return }
                    let delta = Float((factor - 1.0) * 2.0)
                    await self.dollyCamera(delta: delta)
                }
            },
            onRotate: { axis, radians in
                Task { [weak self] in
                    guard let self else { return }
                    if axis == .volume {
                        await self.tiltCamera(roll: Float(radians), pitch: 0)
                        return
                    }
                    guard let controllerAxis = VolumetricSceneController.Axis(axis) else { return }
                    await self.rotate(axis: controllerAxis, radians: Float(radians))
                }
            },
            onWindowLevel: { shift in
                Task { [weak self] in
                    guard let self else { return }
                    await self.setMprHuWindow(min: Int32(shift.level - shift.window / 2),
                                              max: Int32(shift.level + shift.window / 2))
                }
            },
            onSlabThickness: { thickness in
                Task { [weak self] in
                    guard let self else { return }
                    let snaps = VolumetricSceneController.SlabConfiguration(thickness: Int(thickness), steps: 1)
                    await self.setMprSlab(thickness: snaps.thickness, steps: snaps.steps)
                }
            },
            onReset: {
                Task { [weak self] in
                    guard let self else { return }
                    await self.resetCamera()
                }
            }
        )

        return state.makeContext(merging: handler)
    }
}

private extension VolumetricSceneController.Axis {
    init?(_ axis: VolumeGestureAxis) {
        switch axis {
        case .sagittal:
            self = .x
        case .coronal:
            self = .y
        case .axial:
            self = .z
        case .volume:
            return nil
        }
    }
}
#endif
