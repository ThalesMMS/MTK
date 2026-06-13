//
//  MPRDragBaselineTracker.swift
//  MTKUI
//
//  Tracks coalesced MPR drag deltas without sharing baselines across gestures.
//

import CoreGraphics
import MTKCore

struct MPRDragBaselineTracker {
    struct GestureID: Hashable {
        fileprivate let rawValue: UInt64
    }

    private var nextRawValue: UInt64 = 1
    private var activeGestureIDs: [MTKCore.Axis: GestureID] = [:]
    private var appliedTranslations: [GestureID: CGSize] = [:]

    mutating func beginGesture(axis: MTKCore.Axis) -> GestureID {
        let gestureID = GestureID(rawValue: nextRawValue)
        nextRawValue &+= 1
        activeGestureIDs[axis] = gestureID
        return gestureID
    }

    func activeGestureID(for axis: MTKCore.Axis) -> GestureID? {
        activeGestureIDs[axis]
    }

    @discardableResult
    mutating func endGesture(axis: MTKCore.Axis, preserveAppliedTranslation: Bool = false) -> GestureID? {
        let gestureID = activeGestureIDs.removeValue(forKey: axis)
        if !preserveAppliedTranslation, let gestureID {
            appliedTranslations.removeValue(forKey: gestureID)
        }
        return gestureID
    }

    mutating func apply(gestureID: GestureID, translation: CGSize) -> CGSize {
        let previous = appliedTranslations[gestureID] ?? .zero
        appliedTranslations[gestureID] = translation
        return CGSize(
            width: translation.width - previous.width,
            height: translation.height - previous.height
        )
    }

    mutating func clear(gestureID: GestureID) {
        appliedTranslations.removeValue(forKey: gestureID)
        activeGestureIDs = activeGestureIDs.filter { $0.value != gestureID }
    }
}
