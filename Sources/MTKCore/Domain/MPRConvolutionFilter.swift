//
//  MPRConvolutionFilter.swift
//  MTKCore
//
//  Named convolution presets for MPR presentation.
//
//  Thales Matheus Mendonça Santos — July 2026
//

public enum MPRConvolutionFilter: String, CaseIterable, Sendable {
    case blur
    case sharpen
    case unsharpMask
    case edge

    public var kernel: MPRConvolutionKernel {
        switch self {
        case .blur:
            return .blur
        case .sharpen:
            return .sharpen
        case .unsharpMask:
            return .unsharpMask
        case .edge:
            return .edge
        }
    }
}
