//
//  AnatomicalOrientationLabel.swift
//  MTKCore
//
//  Composite anatomical direction labels for oblique MPR display edges.
//

import Foundation

public struct AnatomicalOrientationLabel: Sendable, Equatable, CustomStringConvertible {
    public let components: [AnatomicalAxisLabel]

    public init(components: [AnatomicalAxisLabel]) {
        self.components = components.isEmpty ? [.superior] : components
    }

    public init(_ component: AnatomicalAxisLabel) {
        self.init(components: [component])
    }

    public var opposite: AnatomicalOrientationLabel {
        AnatomicalOrientationLabel(components: components.map(\.opposite))
    }

    public var description: String {
        components.map(\.description).joined()
    }

    public static let right = AnatomicalOrientationLabel(.right)
    public static let left = AnatomicalOrientationLabel(.left)
    public static let anterior = AnatomicalOrientationLabel(.anterior)
    public static let posterior = AnatomicalOrientationLabel(.posterior)
    public static let superior = AnatomicalOrientationLabel(.superior)
    public static let inferior = AnatomicalOrientationLabel(.inferior)
}
