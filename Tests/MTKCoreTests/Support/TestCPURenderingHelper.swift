import CoreGraphics
import Foundation
import simd

@testable import MTKCore

/// Test-only CPU reference renderer for validating volume rendering math.
///
/// This helper intentionally lives in the test target and exists only to
/// produce deterministic reference images for assertions. It is not part of
/// the runtime contract and must not be called by `MetalVolumeRenderingAdapter`.
enum TestCPURenderingHelper {
    /// Builds a grayscale middle-slice reference image using the scalar math
    /// mirrored by the test expectations. Returns `nil` if the dataset cannot
    /// Produce an 8‑bit grayscale reference CGImage for the middle Z slice of a volume dataset using the given window and rendering state.
    /// 
    /// The image is generated deterministically for testing and mirrors the scalar mapping used by the test expectations: it applies the state's shift, axis-aligned clipping, optional density gating, window normalization, piecewise-linear tone curve (with gain), channel intensity scaling, and an optional lighting attenuation. Returns `nil` when the dataset is invalid, a reader cannot be created, or image construction fails.
    /// - Parameters:
    ///   - dataset: The volume dataset to sample; its dimensions and raw data must be valid.
    ///   - window: The inclusive intensity window used for window/level normalization (lowerBound..upperBound).
    ///   - state: Rendering state that supplies `shift`, `clipBounds`, optional `densityGate`, per-channel tone curve points and gains, `channelIntensities`, and `lightingEnabled`.
    /// - Returns: A grayscale `CGImage` representing the middle slice mapped to 0–255, or `nil` if image creation is not possible.
    static func makeReferenceImage(dataset: VolumeDataset,
                                   window: ClosedRange<Int32>,
                                   state: ExtendedRenderingState) -> CGImage? {
        let width = dataset.dimensions.width
        let height = dataset.dimensions.height
        let depth = dataset.dimensions.depth
        guard width > 0, height > 0, depth > 0 else { return nil }
        guard dataset.data.count >= dataset.voxelCount * dataset.pixelFormat.bytesPerVoxel else { return nil }

        let sliceIndex = depth / 2
        let pixelCount = width * height
        var pixels = [UInt8](repeating: 0, count: pixelCount)

        let lower = Float(window.lowerBound)
        let upper = Float(window.upperBound)
        let span = max(upper - lower, Float.leastNonzeroMagnitude)
        var didCreateReader = false

        dataset.data.withUnsafeBytes { buffer in
            guard let reader = VolumeDataReader(dataset: dataset, buffer: buffer) else { return }
            didCreateReader = true

            for y in 0..<height {
                for x in 0..<width {
                    let intensity = reader.intensity(x: x, y: y, z: sliceIndex)
                    let shiftAdjusted = Float(intensity) + state.shift

                    let zNorm = depth > 1 ? Float(sliceIndex) / Float(depth - 1) : 0
                    let xNorm = width > 1 ? Float(x) / Float(width - 1) : 0
                    let yNorm = height > 1 ? Float(y) / Float(height - 1) : 0
                    if !isInsideClipBounds(x: xNorm, y: yNorm, z: zNorm, clip: state.clipBounds) {
                        pixels[y * width + x] = 0
                        continue
                    }

                    if let gate = state.densityGate,
                       shiftAdjusted < gate.lowerBound || shiftAdjusted > gate.upperBound {
                        pixels[y * width + x] = 0
                        continue
                    }

                    var normalized = (shiftAdjusted - lower) / span
                    normalized = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
                    normalized = applyToneCurve(normalized,
                                                points: state.toneCurvePoints[0] ?? [],
                                                gain: state.toneCurveGains[0] ?? 1)

                    let channelGain = state.channelIntensities[0]
                    normalized *= max(channelGain, 0.001)

                    if !state.lightingEnabled {
                        normalized *= 0.5
                    }

                    let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
                    pixels[y * width + x] = UInt8(clamping: Int(round(clamped * 255)))
                }
            }
        }

        guard didCreateReader else { return nil }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()

        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private static func applyToneCurve(_ value: Float, points: [SIMD2<Float>], gain: Float) -> Float {
        guard !points.isEmpty else { return value * gain }
        let safeGain = max(gain, 0)
        let sorted = points.sorted { $0.x < $1.x }
        let clampedValue = VolumetricMath.clampFloat(value, lower: sorted.first!.x, upper: sorted.last!.x)

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            if clampedValue >= start.x && clampedValue <= end.x {
                let t = (clampedValue - start.x) / max(end.x - start.x, 1e-6)
                let mixed = start.y + t * (end.y - start.y)
                return VolumetricMath.clampFloat(mixed, lower: 0, upper: 1) * safeGain
            }
        }
        return clampedValue * safeGain
    }

    private static func isInsideClipBounds(x: Float,
                                           y: Float,
                                           z: Float,
                                           clip: ClipBoundsSnapshot) -> Bool {
        (x >= clip.xMin && x <= clip.xMax) &&
            (y >= clip.yMin && y <= clip.yMax) &&
            (z >= clip.zMin && z <= clip.zMax)
    }
}
