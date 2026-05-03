//
//  ViewportLifecycleController.swift
//  MTK
//
//  Focused helper for viewport lifecycle state transitions.
//

import CoreGraphics

internal struct ViewportLifecycleController {
    struct ViewportStateSnapshot: Equatable {
        var descriptor: ViewportDescriptor
        var currentSize: CGSize
    }

    func resized(_ state: ViewportStateSnapshot, to size: CGSize) -> ViewportStateSnapshot {
        var next = state
        next.currentSize = size
        return next
    }

    func reconfigured(_ state: ViewportStateSnapshot,
                      type: ViewportType,
                      label: String?) -> ViewportStateSnapshot {
        var next = state
        next.descriptor = ViewportDescriptor(type: type,
                                             initialSize: state.currentSize,
                                             label: label ?? state.descriptor.label)
        return next
    }
}
