//
//  MPRScrollStepMapper.swift
//  MTKUI
//

import CoreGraphics

enum MPRScrollStepMapper {
    static func steps(deltaY: CGFloat, hasPreciseScrollingDeltas: Bool) -> Int {
        var adjustedDelta = deltaY
        if hasPreciseScrollingDeltas {
            adjustedDelta *= 0.1
        }
        if adjustedDelta > 0.5 {
            return 1
        }
        if adjustedDelta < -0.5 {
            return -1
        }
        return 0
    }
}
