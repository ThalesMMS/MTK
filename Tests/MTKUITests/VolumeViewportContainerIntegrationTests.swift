#if canImport(SwiftUI)
import XCTest
import Metal
import SwiftUI
@testable import MTKUI

@MainActor
final class VolumeViewportContainerIntegrationTests: XCTestCase {
    func testContainerHostsMetalViewportSurfaceViewAndNotSwiftUIHostingView() throws {
#if os(iOS)
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal not available - skipping GPU-dependent test")

        let controller = try VolumeViewportController()
        let container = ViewportPresentingView(surface: controller.surface)
        let uiView = container.makeUIView(context: .init())

        // Ensure we're hosting the raw render surface view, not a UIHostingController's internal view.
        let hostedSubviews = uiView.subviews
        XCTAssertEqual(hostedSubviews.count, 1)
        XCTAssertTrue(hostedSubviews.first === controller.surface.view)
#else
        throw XCTSkip("Integration test currently implemented for iOS host view inspection")
#endif
    }

    func testContainerHostsMetalRenderSurfaceInSwiftUIHierarchy() throws {
#if os(iOS)
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal not available - skipping GPU-dependent test")

        let controller = try VolumeViewportController()
        let view = VolumeViewportContainer(controller: controller)
        let host = UIHostingController(rootView: view)

        // Force the hosted SwiftUI hierarchy to materialize before searching it.
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        // The render surface should be somewhere in the hosting view hierarchy.
        let renderSurface = findView(withAccessibilityIdentifier: "VolumetricRenderSurface", in: host.view)
        XCTAssertNotNil(renderSurface)
#else
        throw XCTSkip("Integration test currently implemented for iOS host view inspection")
#endif
    }
}

#if os(iOS)
private func findView(withAccessibilityIdentifier identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier { return root }
    for subview in root.subviews {
        if let found = findView(withAccessibilityIdentifier: identifier, in: subview) { return found }
    }
    return nil
}
#endif
#endif
