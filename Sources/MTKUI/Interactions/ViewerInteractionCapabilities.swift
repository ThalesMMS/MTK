//
//  ViewerInteractionCapabilities.swift
//  MTKUI
//
//  Interaction capability model for adaptive viewer UI (issue #1213):
//  chrome and viewports consult these flags instead of hardcoding
//  platform assumptions. Hosts can override per scene (e.g. an iPad app
//  that detects a connected trackpad/keyboard).
//

import SwiftUI

public struct ViewerInteractionCapabilities: Sendable, Equatable {
    public var hasTouch: Bool
    public var hasPointer: Bool
    public var hasHardwareKeyboard: Bool
    public var hasScrollWheel: Bool
    public var supportsModifierKeys: Bool

    public init(
        hasTouch: Bool,
        hasPointer: Bool,
        hasHardwareKeyboard: Bool,
        hasScrollWheel: Bool,
        supportsModifierKeys: Bool
    ) {
        self.hasTouch = hasTouch
        self.hasPointer = hasPointer
        self.hasHardwareKeyboard = hasHardwareKeyboard
        self.hasScrollWheel = hasScrollWheel
        self.supportsModifierKeys = supportsModifierKeys
    }

    /// Touch-first defaults (iPhone/iPad without detected pointer hardware).
    public static let touchOnly = ViewerInteractionCapabilities(
        hasTouch: true,
        hasPointer: false,
        hasHardwareKeyboard: false,
        hasScrollWheel: false,
        supportsModifierKeys: false
    )

    /// iPad with trackpad/keyboard attached.
    public static let tabletWithPointer = ViewerInteractionCapabilities(
        hasTouch: true,
        hasPointer: true,
        hasHardwareKeyboard: true,
        hasScrollWheel: true,
        supportsModifierKeys: true
    )

    /// macOS desktop defaults.
    public static let desktop = ViewerInteractionCapabilities(
        hasTouch: false,
        hasPointer: true,
        hasHardwareKeyboard: true,
        hasScrollWheel: true,
        supportsModifierKeys: true
    )

    /// Conservative platform defaults; hosts override when they detect
    /// pointer/keyboard hardware on iPadOS.
    public static var platformDefault: ViewerInteractionCapabilities {
#if os(macOS)
        .desktop
#else
        .touchOnly
#endif
    }
}

private struct ViewerInteractionCapabilitiesKey: EnvironmentKey {
    static let defaultValue: ViewerInteractionCapabilities = .platformDefault
}

extension EnvironmentValues {
    public var viewerInteractionCapabilities: ViewerInteractionCapabilities {
        get { self[ViewerInteractionCapabilitiesKey.self] }
        set { self[ViewerInteractionCapabilitiesKey.self] = newValue }
    }
}

extension View {
    /// Overrides the interaction capabilities for this hierarchy.
    public func viewerInteractionCapabilities(
        _ capabilities: ViewerInteractionCapabilities
    ) -> some View {
        environment(\.viewerInteractionCapabilities, capabilities)
    }
}
