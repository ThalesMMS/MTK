//
//  MPRCameraConfiguration.swift
//  MTKCore
//
//  Helpers for computing parallelScale/viewUp values for
//  multi-planar reconstruction (MPR) and orthographic rendering.

import simd

public struct MPRCameraConfiguration {
    public enum SlicingMode {
        case axial      // Z - visualiza XY
        case sagittal   // X - visualiza YZ
        case coronal    // Y - visualiza XZ
    }

    /// Calcula parallelScale e viewUp para um modo de fatiamento.
    /// - Parameters:
    ///   - mode: Modo de fatiamento (axial/sagittal/coronal)
    ///   - bounds: Limites axis-aligned [xMin, xMax, yMin, yMax, zMin, zMax]
    /// - Returns: parallelScale (metade da altura do viewport em unidades de mundo) e viewUp sugerido
    public static func configure(mode: SlicingMode,
                                 bounds: [Float]) -> (parallelScale: Float, viewUp: SIMD3<Float>) {
        guard bounds.count >= 6 else {
            return (1, SIMD3<Float>(0, 1, 0))
        }

        switch mode {
        case .axial:    // Visualiza XY (plano Z)
            let extensionY = bounds[3] - bounds[2]
            return (max(extensionY * 0.5, 1e-3), SIMD3<Float>(0, 1, 0))
        case .sagittal: // Visualiza YZ (plano X)
            let extensionZ = bounds[5] - bounds[4]
            return (max(extensionZ * 0.5, 1e-3), SIMD3<Float>(0, 0, 1))
        case .coronal:  // Visualiza XZ (plano Y)
            let extensionZ = bounds[5] - bounds[4]
            return (max(extensionZ * 0.5, 1e-3), SIMD3<Float>(0, 0, 1))
        }
    }

    /// Calcula parallelScale para mapeamento 1:1 (1 pixel = 1 unidade de mundo).
    public static func scaleForOneToOneMapping(viewportHeightPixels: Float) -> Float {
        viewportHeightPixels * 0.5
    }

    /// Retorna quantas unidades de mundo correspondem a um pixel para um parallelScale.
    public static func worldUnitsPerPixel(parallelScale: Float,
                                          viewportHeightPixels: Float) -> Float {
        guard viewportHeightPixels > Float.ulpOfOne else { return 0 }
        return (2.0 * parallelScale) / viewportHeightPixels
    }

    /// Calcula bounds axis-aligned no espaço do mundo para um dataset.
    /// Útil para alimentar o configure(mode:bounds:) com limites coerentes.
    public static func worldBounds(for dataset: VolumeDataset) -> [Float] {
        let dims = dataset.dimensions
        guard dims.width > 0, dims.height > 0, dims.depth > 0 else { return [0, 0, 0, 0, 0, 0] }

        let spacing = dataset.spacing
        let maxX = Float(dims.width - 1)
        let maxY = Float(dims.height - 1)
        let maxZ = Float(dims.depth - 1)

        let boundsMin = SIMD3<Float>(0, 0, 0)
        let boundsMax = SIMD3<Float>(maxX, maxY, maxZ)

        let origin = dataset.orientation.origin
        let row = dataset.orientation.row
        let col = dataset.orientation.column
        let normal = simd_normalize(simd_cross(row, col))

        let volumeToWorld = simd_float4x4(
            columns: (
                SIMD4<Float>(row * Float(spacing.x), 0),
                SIMD4<Float>(col * Float(spacing.y), 0),
                SIMD4<Float>(normal * Float(spacing.z), 0),
                SIMD4<Float>(origin, 1)
            )
        )

        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(boundsMin.x, boundsMin.y, boundsMin.z),
            SIMD3<Float>(boundsMin.x, boundsMin.y, boundsMax.z),
            SIMD3<Float>(boundsMin.x, boundsMax.y, boundsMin.z),
            SIMD3<Float>(boundsMin.x, boundsMax.y, boundsMax.z),
            SIMD3<Float>(boundsMax.x, boundsMin.y, boundsMin.z),
            SIMD3<Float>(boundsMax.x, boundsMin.y, boundsMax.z),
            SIMD3<Float>(boundsMax.x, boundsMax.y, boundsMin.z),
            SIMD3<Float>(boundsMax.x, boundsMax.y, boundsMax.z)
        ]

        var minCorner = SIMD3<Float>(repeating: .infinity)
        var maxCorner = SIMD3<Float>(repeating: -.infinity)

        for corner in corners {
            let worldCorner4 = volumeToWorld * SIMD4<Float>(corner, 1)
            let worldCorner = SIMD3<Float>(worldCorner4.x, worldCorner4.y, worldCorner4.z)
            minCorner = simd_min(minCorner, worldCorner)
            maxCorner = simd_max(maxCorner, worldCorner)
        }

        return [minCorner.x, maxCorner.x, minCorner.y, maxCorner.y, minCorner.z, maxCorner.z]
    }
}
