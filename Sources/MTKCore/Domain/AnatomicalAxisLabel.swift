//
//  AnatomicalAxisLabel.swift
//  MTKCore
//
//  Explicit anatomical edge labels for MPR display orientation contracts.
//

import Foundation

public enum AnatomicalAxisLabel: CaseIterable, Sendable, Equatable, CustomStringConvertible {
    case right
    case left
    case anterior
    case posterior
    case superior
    case inferior

    public var opposite: AnatomicalAxisLabel {
        switch self {
        case .right:
            return .left
        case .left:
            return .right
        case .anterior:
            return .posterior
        case .posterior:
            return .anterior
        case .superior:
            return .inferior
        case .inferior:
            return .superior
        }
    }

    public var lpsAxis: Int {
        switch self {
        case .right, .left:
            return 0
        case .anterior, .posterior:
            return 1
        case .superior, .inferior:
            return 2
        }
    }

    public var isPositiveLPS: Bool {
        switch self {
        case .left, .posterior, .superior:
            return true
        case .right, .anterior, .inferior:
            return false
        }
    }

    public var description: String {
        switch self {
        case .right:
            return "R"
        case .left:
            return "L"
        case .anterior:
            return "A"
        case .posterior:
            return "P"
        case .superior:
            return "S"
        case .inferior:
            return "I"
        }
    }
}
