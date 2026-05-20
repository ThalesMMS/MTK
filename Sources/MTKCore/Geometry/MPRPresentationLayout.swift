//
//  MPRPresentationLayout.swift
//  MTKCore
//
//  Shared aspect-fit layout used by the MPR presentation pass and by
//  picking/overlay coordinate conversions, so both apply the same
//  drawable<->image mapping (no letterbox drift between rendered pixels
//  and the crosshair overlay).
//

import CoreGraphics
import simd

/// Normalized layout describing where an aspect-fit image is placed inside a
/// rectangular destination (e.g., a Metal drawable). `origin` and `size` are
/// expressed in the destination's normalized coordinates `[0, 1]`.
public struct MPRPresentationLayout: Equatable, Sendable {
    public var origin: SIMD2<Float>
    public var size: SIMD2<Float>

    /// Layout that fills the entire destination without aspect correction.
    public static let fill = MPRPresentationLayout(origin: .zero,
                                                   size: SIMD2<Float>(1, 1))

    public init(origin: SIMD2<Float>, size: SIMD2<Float>) {
        self.origin = origin
        self.size = size
    }

    /// Computes an aspect-fit layout that preserves `contentAspectRatio`
    /// (width/height) inside a destination of the given pixel dimensions,
    /// centering the content with letterbox/pillarbox bands when the
    /// destination aspect differs from the content aspect.
    public static func aspectFit(contentAspectRatio: Float,
                                 destinationWidth: Int,
                                 destinationHeight: Int) -> MPRPresentationLayout {
        let width = max(Float(destinationWidth), 1)
        let height = max(Float(destinationHeight), 1)
        let destinationAspect = width / height
        let contentAspect = max(contentAspectRatio, Float.ulpOfOne)

        let normalizedSize: SIMD2<Float>
        if destinationAspect > contentAspect {
            normalizedSize = SIMD2<Float>(contentAspect / destinationAspect, 1)
        } else {
            normalizedSize = SIMD2<Float>(1, destinationAspect / contentAspect)
        }
        let origin = (SIMD2<Float>(repeating: 1) - normalizedSize) * 0.5
        return MPRPresentationLayout(origin: origin, size: normalizedSize)
    }

    /// Maps a point in the image's normalized space `[0, 1]^2` (where the
    /// rendered image lives) into the destination's normalized space.
    public func viewportPoint(fromImagePoint imagePoint: SIMD2<Float>) -> SIMD2<Float> {
        origin + imagePoint * size
    }

    /// Inverse of `viewportPoint(fromImagePoint:)`. Returns `nil` if the
    /// supplied destination point falls outside the image rect (the
    /// letterbox/pillarbox band).
    public func imagePoint(fromViewportPoint viewportPoint: SIMD2<Float>,
                           tolerance: Float = 1e-4) -> SIMD2<Float>? {
        let safeSize = SIMD2<Float>(max(size.x, Float.ulpOfOne),
                                    max(size.y, Float.ulpOfOne))
        let normalized = (viewportPoint - origin) / safeSize
        if normalized.x < -tolerance || normalized.x > 1 + tolerance ||
            normalized.y < -tolerance || normalized.y > 1 + tolerance {
            return nil
        }
        return SIMD2<Float>(min(max(normalized.x, 0), 1),
                            min(max(normalized.y, 0), 1))
    }
}

/// How the MPR presentation pass maps the rendered slab into the destination
/// drawable. Picking and overlay code must use the same mode that the
/// presentation pass used, otherwise the crosshair drifts off the anatomy
/// whenever the plane's physical aspect ratio differs from the drawable's.
public enum MPROutputAspect: Sendable, Equatable {
    /// Image stretches to fill the entire destination (no letterbox).
    case fill
    /// Image is aspect-fit using the plane's physical aspect ratio
    /// (`|axisUWorld| / |axisVWorld|`), matching `MPRPresentationPass`.
    case aspectFit(physicalAspectRatio: Float)

    /// Resolves the layout for a given destination size in pixels/points.
    public func layout(destinationWidth: Int,
                       destinationHeight: Int) -> MPRPresentationLayout {
        switch self {
        case .fill:
            return .fill
        case let .aspectFit(physicalAspectRatio):
            return .aspectFit(contentAspectRatio: physicalAspectRatio,
                              destinationWidth: destinationWidth,
                              destinationHeight: destinationHeight)
        }
    }

    /// Convenience that resolves the layout for a destination of given size.
    public func layout(destinationSize: CGSize) -> MPRPresentationLayout {
        let width = max(Int(destinationSize.width.rounded()), 1)
        let height = max(Int(destinationSize.height.rounded()), 1)
        return layout(destinationWidth: width, destinationHeight: height)
    }
}
