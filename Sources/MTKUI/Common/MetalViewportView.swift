#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI
import MTKCore

/// SwiftUI viewport for MTKUI's Metal-backed clinical presentation surface.
///
/// `MetalViewportView` is the public SwiftUI host used by MTKUI containers. It
/// keeps the clinical UI contract centered on MTKUI/MTKCore render surfaces
/// rather than legacy view wrappers.
@MainActor
public struct MetalViewportView: View {
    public let surface: any ViewportPresenting

    public init(surface: any ViewportPresenting) {
        self.surface = surface
    }

    public var body: some View {
        ViewportPresentingView(surface: surface)
    }
}
#endif
