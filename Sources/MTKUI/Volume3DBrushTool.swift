import CoreGraphics
import Foundation
import MTKCore
import simd

public enum VolumeBrushMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case erase
    case restore

    public var id: String { rawValue }
}

public struct VolumeBrushState: Equatable, Sendable {
    public static let defaultBrushSizeMM: Double = 40
    public static let minimumBrushSizeMM: Double = 1
    public static let maximumBrushSizeMM: Double = 200
    public static let brushSizeStepMM: Double = 5

    public var isEnabled: Bool
    public var brushSizeMM: Double
    public var mode: VolumeBrushMode

    public init(isEnabled: Bool = false,
                brushSizeMM: Double = Self.defaultBrushSizeMM,
                mode: VolumeBrushMode = .erase) {
        self.isEnabled = isEnabled
        self.brushSizeMM = Self.clampedBrushSize(brushSizeMM)
        self.mode = mode
    }

    public func settingEnabled(_ enabled: Bool) -> VolumeBrushState {
        VolumeBrushState(isEnabled: enabled,
                         brushSizeMM: brushSizeMM,
                         mode: mode)
    }

    public func settingBrushSizeMM(_ value: Double) -> VolumeBrushState {
        VolumeBrushState(isEnabled: isEnabled,
                         brushSizeMM: value,
                         mode: mode)
    }

    public func adjustingBrushSizeMM(by delta: Double) -> VolumeBrushState {
        settingBrushSizeMM(brushSizeMM + delta)
    }

    public func settingMode(_ mode: VolumeBrushMode) -> VolumeBrushState {
        VolumeBrushState(isEnabled: isEnabled,
                         brushSizeMM: brushSizeMM,
                         mode: mode)
    }

    public static func clampedBrushSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBrushSizeMM }
        return min(max(value, minimumBrushSizeMM), maximumBrushSizeMM)
    }
}

public enum Volume3DBrushToolMenu {
    public static func menu(state: VolumeBrushState) -> ViewerToolMenu {
        let size = Int(state.brushSizeMM.rounded())
        return ViewerToolMenu(title: "Brush size (\(size) mm)", items: [
            ViewerToolMenuItem(id: "volume3d-brush-size-decrease",
                               title: "Smaller",
                               systemImage: "minus",
                               action: .adjust3DBrushSize(-VolumeBrushState.brushSizeStepMM),
                               isEnabled: state.brushSizeMM > VolumeBrushState.minimumBrushSizeMM),
            ViewerToolMenuItem(id: "volume3d-brush-size-increase",
                               title: "Larger",
                               systemImage: "plus",
                               action: .adjust3DBrushSize(VolumeBrushState.brushSizeStepMM),
                               isEnabled: state.brushSizeMM < VolumeBrushState.maximumBrushSizeMM),
            ViewerToolMenuItem(id: "volume3d-brush-mode-erase",
                               title: "Erase",
                               systemImage: state.mode == .erase ? "checkmark" : nil,
                               action: .set3DBrushMode(.erase)),
            ViewerToolMenuItem(id: "volume3d-brush-mode-restore",
                               title: "Restore",
                               systemImage: state.mode == .restore ? "checkmark" : nil,
                               action: .set3DBrushMode(.restore)),
            ViewerToolMenuItem(id: "volume3d-brush-reset-volume",
                               title: "Reset volume",
                               systemImage: "arrow.counterclockwise",
                               action: .reset3DBrushVolume),
            ViewerToolMenuItem(id: "volume3d-brush-select",
                               title: "Select Brush tool",
                               systemImage: "paintbrush.pointed",
                               action: .selectTool(.brush))
        ])
    }
}

public enum VolumeBrushMaskError: Error, Equatable, LocalizedError {
    case invalidDataSize(expected: Int, actual: Int)
    case invalidDimensions
    case invalidBrushCenter

    public var errorDescription: String? {
        switch self {
        case .invalidDataSize(let expected, let actual):
            return "Volume brush mask expected \(expected) bytes, got \(actual)."
        case .invalidDimensions:
            return "Volume brush mask requires positive volume dimensions."
        case .invalidBrushCenter:
            return "Volume brush mask requires a finite brush center."
        }
    }
}

public struct VolumeBrushMaskEditResult: Equatable, Sendable {
    public var dataset: VolumeDataset
    public var affectedVoxelCount: Int

    public init(dataset: VolumeDataset,
                affectedVoxelCount: Int) {
        self.dataset = dataset
        self.affectedVoxelCount = affectedVoxelCount
    }
}

public enum VolumeBrushMask {
    public static func applyingStroke(to dataset: VolumeDataset,
                                      existingMaskedData: Data? = nil,
                                      centerVoxel: SIMD3<Float>,
                                      brushSizeMM: Double,
                                      mode: VolumeBrushMode) throws -> VolumeBrushMaskEditResult {
        let dimensions = dataset.dimensions
        guard dimensions.width > 0, dimensions.height > 0, dimensions.depth > 0 else {
            throw VolumeBrushMaskError.invalidDimensions
        }
        guard centerVoxel.x.isFinite, centerVoxel.y.isFinite, centerVoxel.z.isFinite else {
            throw VolumeBrushMaskError.invalidBrushCenter
        }

        let expectedByteCount = dimensions.voxelCount * dataset.pixelFormat.bytesPerVoxel
        guard dataset.data.count == expectedByteCount else {
            throw VolumeBrushMaskError.invalidDataSize(expected: expectedByteCount,
                                                      actual: dataset.data.count)
        }

        var maskedData = existingMaskedData ?? dataset.data
        guard maskedData.count == expectedByteCount else {
            throw VolumeBrushMaskError.invalidDataSize(expected: expectedByteCount,
                                                      actual: maskedData.count)
        }

        let radiusMM = max(VolumeBrushState.clampedBrushSize(brushSizeMM) * 0.5, 0.5)
        let bounds = brushBounds(centerVoxel: centerVoxel,
                                 radiusMM: radiusMM,
                                 dimensions: dimensions,
                                 spacing: dataset.spacing)
        let affected: Int
        switch dataset.pixelFormat {
        case .int16Signed:
            let eraseValue = Int16(clamping: dataset.intensityRange.lowerBound)
            affected = editSigned(maskedData: &maskedData,
                                  originalData: dataset.data,
                                  dimensions: dimensions,
                                  spacing: dataset.spacing,
                                  centerVoxel: centerVoxel,
                                  radiusMM: radiusMM,
                                  bounds: bounds,
                                  mode: mode,
                                  eraseValue: eraseValue)
        case .int16Unsigned:
            let eraseValue = UInt16(clamping: max(Int32(0), dataset.intensityRange.lowerBound))
            affected = editUnsigned(maskedData: &maskedData,
                                    originalData: dataset.data,
                                    dimensions: dimensions,
                                    spacing: dataset.spacing,
                                    centerVoxel: centerVoxel,
                                    radiusMM: radiusMM,
                                    bounds: bounds,
                                    mode: mode,
                                    eraseValue: eraseValue)
        }

        var maskedDataset = dataset
        maskedDataset.data = maskedData
        return VolumeBrushMaskEditResult(dataset: maskedDataset,
                                         affectedVoxelCount: affected)
    }

    private struct BrushBounds {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var minZ: Int
        var maxZ: Int
    }

    private static func brushBounds(centerVoxel: SIMD3<Float>,
                                    radiusMM: Double,
                                    dimensions: VolumeDimensions,
                                    spacing: VolumeSpacing) -> BrushBounds {
        let spacingX = safeSpacing(spacing.x)
        let spacingY = safeSpacing(spacing.y)
        let spacingZ = safeSpacing(spacing.z)
        return BrushBounds(
            minX: max(0, Int(floor(Double(centerVoxel.x) - radiusMM / spacingX))),
            maxX: min(dimensions.width - 1, Int(ceil(Double(centerVoxel.x) + radiusMM / spacingX))),
            minY: max(0, Int(floor(Double(centerVoxel.y) - radiusMM / spacingY))),
            maxY: min(dimensions.height - 1, Int(ceil(Double(centerVoxel.y) + radiusMM / spacingY))),
            minZ: max(0, Int(floor(Double(centerVoxel.z) - radiusMM / spacingZ))),
            maxZ: min(dimensions.depth - 1, Int(ceil(Double(centerVoxel.z) + radiusMM / spacingZ)))
        )
    }

    private static func editSigned(maskedData: inout Data,
                                   originalData: Data,
                                   dimensions: VolumeDimensions,
                                   spacing: VolumeSpacing,
                                   centerVoxel: SIMD3<Float>,
                                   radiusMM: Double,
                                   bounds: BrushBounds,
                                   mode: VolumeBrushMode,
                                   eraseValue: Int16) -> Int {
        edit(maskedData: &maskedData,
             originalData: originalData,
             dimensions: dimensions,
             spacing: spacing,
             centerVoxel: centerVoxel,
             radiusMM: radiusMM,
             bounds: bounds) { masked, original, linear in
            let maskedBuffer = masked.bindMemory(to: Int16.self)
            let originalBuffer = original.bindMemory(to: Int16.self)
            switch mode {
            case .erase:
                maskedBuffer[linear] = eraseValue
            case .restore:
                maskedBuffer[linear] = originalBuffer[linear]
            }
        }
    }

    private static func editUnsigned(maskedData: inout Data,
                                     originalData: Data,
                                     dimensions: VolumeDimensions,
                                     spacing: VolumeSpacing,
                                     centerVoxel: SIMD3<Float>,
                                     radiusMM: Double,
                                     bounds: BrushBounds,
                                     mode: VolumeBrushMode,
                                     eraseValue: UInt16) -> Int {
        edit(maskedData: &maskedData,
             originalData: originalData,
             dimensions: dimensions,
             spacing: spacing,
             centerVoxel: centerVoxel,
             radiusMM: radiusMM,
             bounds: bounds) { masked, original, linear in
            let maskedBuffer = masked.bindMemory(to: UInt16.self)
            let originalBuffer = original.bindMemory(to: UInt16.self)
            switch mode {
            case .erase:
                maskedBuffer[linear] = eraseValue
            case .restore:
                maskedBuffer[linear] = originalBuffer[linear]
            }
        }
    }

    private static func edit(maskedData: inout Data,
                             originalData: Data,
                             dimensions: VolumeDimensions,
                             spacing: VolumeSpacing,
                             centerVoxel: SIMD3<Float>,
                             radiusMM: Double,
                             bounds: BrushBounds,
                             apply: (UnsafeMutableRawBufferPointer, UnsafeRawBufferPointer, Int) -> Void) -> Int {
        guard bounds.minX <= bounds.maxX,
              bounds.minY <= bounds.maxY,
              bounds.minZ <= bounds.maxZ else {
            return 0
        }
        let spacingX = safeSpacing(spacing.x)
        let spacingY = safeSpacing(spacing.y)
        let spacingZ = safeSpacing(spacing.z)
        let radiusSquared = radiusMM * radiusMM
        var affected = 0
        maskedData.withUnsafeMutableBytes { maskedBuffer in
            originalData.withUnsafeBytes { originalBuffer in
                for z in bounds.minZ...bounds.maxZ {
                    for y in bounds.minY...bounds.maxY {
                        for x in bounds.minX...bounds.maxX {
                            let dx = (Double(x) - Double(centerVoxel.x)) * spacingX
                            let dy = (Double(y) - Double(centerVoxel.y)) * spacingY
                            let dz = (Double(z) - Double(centerVoxel.z)) * spacingZ
                            guard dx * dx + dy * dy + dz * dz <= radiusSquared else {
                                continue
                            }

                            let linear = (z * dimensions.height + y) * dimensions.width + x
                            apply(maskedBuffer, originalBuffer, linear)
                            affected += 1
                        }
                    }
                }
            }
        }
        return affected
    }

    private static func safeSpacing(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }
}

public enum Volume3DBrushCursorLayout {
    public static func screenRadius(brushSizeMM: Double,
                                    viewportSize: CGSize) -> CGFloat {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return 0
        }
        let clampedSize = VolumeBrushState.clampedBrushSize(brushSizeMM)
        let minSide = min(viewportSize.width, viewportSize.height)
        let diameter = minSide * CGFloat(clampedSize / 240)
        return min(max(diameter * 0.5, 8), minSide * 0.35)
    }
}

#if canImport(SwiftUI)
import SwiftUI

public struct Volume3DBrushOverlay: View {
    private let state: VolumeBrushState
    private let cursorLocation: CGPoint?
    private let onBrushPoint: (CGPoint) -> Void
    private let onBrushEnded: () -> Void
    @State private var dragCursorLocation: CGPoint?

    public init(state: VolumeBrushState,
                cursorLocation: CGPoint?,
                onBrushPoint: @escaping (CGPoint) -> Void,
                onBrushEnded: @escaping () -> Void) {
        self.state = state
        self.cursorLocation = cursorLocation
        self.onBrushPoint = onBrushPoint
        self.onBrushEnded = onBrushEnded
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if state.isEnabled, let cursor = dragCursorLocation ?? cursorLocation {
                    brushCursor(at: cursor,
                                radius: Volume3DBrushCursorLayout.screenRadius(brushSizeMM: state.brushSizeMM,
                                                                              viewportSize: size))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(brushGesture)
        }
        .allowsHitTesting(state.isEnabled)
        .accessibilityIdentifier("Volume3DBrushOverlay")
    }

    private var brushGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragCursorLocation = value.location
                onBrushPoint(value.location)
            }
            .onEnded { _ in
                dragCursorLocation = nil
                onBrushEnded()
            }
    }

    private func brushCursor(at point: CGPoint,
                             radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.cyan.opacity(0.92), lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color.cyan.opacity(0.9))
                .frame(width: 5, height: 5)
        }
        .position(point)
        .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
        .accessibilityIdentifier("Volume3DBrushOverlay.cursor")
    }
}
#endif
