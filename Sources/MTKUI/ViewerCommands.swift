//
//  ViewerCommands.swift
//  MTKUI
//
//  Command model shared by desktop chrome, app-level menus and keyboard
//  integration (issues #1212/#1213). Apps bridge descriptors into SwiftUI
//  `.commands` menus or local keyboard shortcuts; MTKUI renders them in
//  toolbars and dispatches selection through a plain callback.
//

import SwiftUI

/// Stable identifiers for common viewer actions.
public enum ViewerCommandID: String, CaseIterable, Identifiable, Sendable {
    case switchTo2D
    case switchToMPR
    case switchTo3D
    case resetView
    case toggleCrosshair
    case toggleAnnotations
    case toggleFullscreenViewport
    case cycleMPRLayout
    case exportSnapshot

    public var id: String { rawValue }
}

/// Modifier keys for a command's key equivalent, kept platform-neutral so
/// descriptors stay testable without SwiftUI types.
public struct ViewerCommandModifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ViewerCommandModifiers(rawValue: 1 << 0)
    public static let shift = ViewerCommandModifiers(rawValue: 1 << 1)
    public static let option = ViewerCommandModifiers(rawValue: 1 << 2)
    public static let control = ViewerCommandModifiers(rawValue: 1 << 3)

    /// SwiftUI event modifiers for `.keyboardShortcut` bridging.
    public var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.command) { modifiers.insert(.command) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

/// A viewer action that chrome toolbars render and app menus can mirror.
public struct ViewerCommandDescriptor: Identifiable, Equatable, Sendable {
    public let id: ViewerCommandID
    public let title: String
    public let systemImage: String
    /// Single-character key equivalent (lowercase), nil when the command has
    /// no default shortcut.
    public let key: Character?
    public let modifiers: ViewerCommandModifiers

    public init(
        id: ViewerCommandID,
        title: String,
        systemImage: String,
        key: Character? = nil,
        modifiers: ViewerCommandModifiers = []
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.key = key
        self.modifiers = modifiers
    }

    /// SwiftUI shortcut for menu/keyboard bridging, when a key is defined.
    public var keyboardShortcut: KeyboardShortcut? {
        guard let key else { return nil }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers.eventModifiers)
    }

    public var accessibilityIdentifier: String {
        "ViewerCommand.\(id.rawValue)"
    }
}

extension ViewerCommandDescriptor {
    /// Default command set for clinical viewing. Hosts may filter or extend.
    public static let defaultViewerCommands: [ViewerCommandDescriptor] = [
        ViewerCommandDescriptor(id: .switchTo2D, title: "2D Stack", systemImage: "rectangle", key: "1"),
        ViewerCommandDescriptor(id: .switchToMPR, title: "MPR", systemImage: "square.grid.2x2", key: "2"),
        ViewerCommandDescriptor(id: .switchTo3D, title: "3D", systemImage: "cube.transparent", key: "3"),
        ViewerCommandDescriptor(id: .resetView, title: "Reset View", systemImage: "arrow.counterclockwise", key: "r"),
        ViewerCommandDescriptor(id: .toggleCrosshair, title: "Crosshair", systemImage: "plus", key: "x"),
        ViewerCommandDescriptor(id: .toggleAnnotations, title: "Annotations", systemImage: "textformat", key: "a"),
        ViewerCommandDescriptor(
            id: .toggleFullscreenViewport, title: "Fullscreen Pane",
            systemImage: "arrow.up.left.and.arrow.down.right", key: "f"
        ),
        ViewerCommandDescriptor(id: .cycleMPRLayout, title: "Cycle MPR Layout", systemImage: "rectangle.split.3x1", key: "l"),
        ViewerCommandDescriptor(id: .exportSnapshot, title: "Export Snapshot", systemImage: "camera", key: "e", modifiers: [.command, .shift])
    ]

    /// The viewer mode a mode-switching command maps to, nil for the rest.
    public var targetMode: ClinicalViewerMode? {
        switch id {
        case .switchTo2D: return .stack2D
        case .switchToMPR: return .clinical
        case .switchTo3D: return .single3D
        default: return nil
        }
    }
}
