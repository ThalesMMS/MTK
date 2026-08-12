//
//  MPRConvolutionFilter.swift
//  MTK
//
//  Named convolution presets for MPR presentation.
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
