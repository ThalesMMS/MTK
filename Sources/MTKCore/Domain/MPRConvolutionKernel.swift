//
//  MPRConvolutionKernel.swift
//  MTK
//
//  Raw-intensity 2D convolution kernels for MPR presentation.
//

import Foundation

public struct MPRConvolutionKernel: Equatable, Hashable, Sendable {
    public static let maximumSize = 31

    public let size: Int
    public let weights: [Float]

    public init?(size: Int, weights: [Float]) {
        guard size > 0,
              size <= Self.maximumSize,
              size.isMultiple(of: 2) == false,
              weights.count == size * size,
              weights.allSatisfy(\.isFinite) else {
            return nil
        }
        self.size = size
        self.weights = weights
    }

    public static let identity = MPRConvolutionKernel(size: 1, weights: [1])!

    public static let blur = MPRConvolutionKernel(
        size: 3,
        weights: [
            1.0 / 16, 2.0 / 16, 1.0 / 16,
            2.0 / 16, 4.0 / 16, 2.0 / 16,
            1.0 / 16, 2.0 / 16, 1.0 / 16
        ]
    )!

    public static let sharpen = MPRConvolutionKernel(
        size: 3,
        weights: [
             0, -1,  0,
            -1,  5, -1,
             0, -1,  0
        ]
    )!

    public static let unsharpMask = MPRConvolutionKernel(
        size: 5,
        weights: [
            -1.0 / 256,  -4.0 / 256,  -6.0 / 256,  -4.0 / 256, -1.0 / 256,
            -4.0 / 256, -16.0 / 256, -24.0 / 256, -16.0 / 256, -4.0 / 256,
            -6.0 / 256, -24.0 / 256, 476.0 / 256, -24.0 / 256, -6.0 / 256,
            -4.0 / 256, -16.0 / 256, -24.0 / 256, -16.0 / 256, -4.0 / 256,
            -1.0 / 256,  -4.0 / 256,  -6.0 / 256,  -4.0 / 256, -1.0 / 256
        ]
    )!

    public static let edge = MPRConvolutionKernel(
        size: 3,
        weights: [
            -1, -1, -1,
            -1,  8, -1,
            -1, -1, -1
        ]
    )!
}
