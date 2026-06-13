//
//  ViewerLayoutClass.swift
//  MTKUI
//
//  Reusable layout-class abstraction for viewer chrome and grids (issue
//  #1210). Components resolve their layout strategy from a small, testable
//  context instead of embedding size-class decisions per view, and previews/
//  tests can inject a class explicitly via `.viewerLayoutClass(_:)`.
//

import SwiftUI

/// The layout strategy a viewer component should adopt.
///
/// - `compactPhone`: compact-width portrait windows — iPhone portrait and
///   narrow iPad split-view panes. Stacked compact chrome.
/// - `compactTablet`: intermediate windows — phone landscape (compact
///   height) and narrow regular-width windows such as Stage Manager or
///   split view below ``ViewerLayoutClassResolver/tabletWidthBreakpoint``.
/// - `tablet`: regular-width iPad windows at or above the tablet breakpoint.
/// - `desktop`: macOS windows.
public enum ViewerLayoutClass: String, Sendable, Equatable, CaseIterable {
    case compactPhone
    case compactTablet
    case tablet
    case desktop
}

/// Inputs for layout-class resolution. All fields are optional-friendly so
/// previews and tests can build contexts without a real environment.
public struct ViewerLayoutContext: Sendable, Equatable {
    /// Available container size in points. `.zero` means unknown.
    public var size: CGSize
    /// `true`/`false` when the horizontal size class is known, nil otherwise.
    public var horizontalSizeClassIsCompact: Bool?
    /// `true`/`false` when the vertical size class is known, nil otherwise.
    public var verticalSizeClassIsCompact: Bool?
    /// Desktop idioms (persistent pointer, menu bar, resizable windows).
    /// Defaults to `true` when built on macOS.
    public var prefersDesktopIdioms: Bool

    public init(
        size: CGSize = .zero,
        horizontalSizeClassIsCompact: Bool? = nil,
        verticalSizeClassIsCompact: Bool? = nil,
        prefersDesktopIdioms: Bool = ViewerLayoutContext.platformPrefersDesktopIdioms
    ) {
        self.size = size
        self.horizontalSizeClassIsCompact = horizontalSizeClassIsCompact
        self.verticalSizeClassIsCompact = verticalSizeClassIsCompact
        self.prefersDesktopIdioms = prefersDesktopIdioms
    }

    public static var platformPrefersDesktopIdioms: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }
}

/// Deterministic layout-class resolution shared by viewer chrome and grids.
public enum ViewerLayoutClassResolver {
    /// Width at or above which a regular-width window counts as a tablet
    /// surface (mirrors the demo-shell breakpoint).
    public static let tabletWidthBreakpoint: CGFloat = 700
    /// Width at or above which a compact-width window stops being treated
    /// as phone-like when size classes are unknown.
    public static let phoneWidthBreakpoint: CGFloat = 500

    public static func resolve(_ context: ViewerLayoutContext) -> ViewerLayoutClass {
        if context.prefersDesktopIdioms {
            return .desktop
        }

        let width = context.size.width

        // Phone landscape: vertically compact windows never stack the
        // compact-phone chrome; they get the intermediate class.
        if context.verticalSizeClassIsCompact == true {
            return .compactTablet
        }

        // Compact-width portrait windows (phones, narrow iPad splits) keep
        // the compact chrome path.
        if context.horizontalSizeClassIsCompact == true {
            return .compactPhone
        }

        // Regular width: split tablet vs narrow Stage Manager/split windows.
        if context.horizontalSizeClassIsCompact == false {
            if width > 0 && width < tabletWidthBreakpoint {
                return .compactTablet
            }
            return .tablet
        }

        // Unknown size classes (previews/tests with raw sizes): use widths.
        if width > 0 {
            if width < phoneWidthBreakpoint { return .compactPhone }
            if width < tabletWidthBreakpoint { return .compactTablet }
        }
        return .tablet
    }
}

// MARK: - Environment override

private struct ViewerLayoutClassOverrideKey: EnvironmentKey {
    static let defaultValue: ViewerLayoutClass? = nil
}

extension EnvironmentValues {
    /// Explicit layout class injected by previews, tests, or downstream
    /// shells. When set, viewer components skip resolution and use it as-is.
    public var viewerLayoutClassOverride: ViewerLayoutClass? {
        get { self[ViewerLayoutClassOverrideKey.self] }
        set { self[ViewerLayoutClassOverrideKey.self] = newValue }
    }
}

extension View {
    /// Forces a specific viewer layout class on this hierarchy (previews,
    /// tests, or shells that resolve the class themselves).
    public func viewerLayoutClass(_ layoutClass: ViewerLayoutClass?) -> some View {
        environment(\.viewerLayoutClassOverride, layoutClass)
    }
}
