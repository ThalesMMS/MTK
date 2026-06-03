#if canImport(SwiftUI)
import XCTest
import Metal
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import MTKUI

@MainActor
final class VolumeViewportContainerIntegrationTests: XCTestCase {
    func testContainerHostsMetalViewportSurfaceViewAndNotSwiftUIHostingView() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal not available - skipping GPU-dependent test")

        let controller = try VolumeViewportController()
#if os(iOS)
        let container = ViewportPresentingView.ContainerView(frame: .zero)
        container.host(controller.surface.view)

        // Ensure we're hosting the raw render surface view, not a UIHostingController's internal view.
        let hostedSubviews = container.subviews
        XCTAssertEqual(hostedSubviews.count, 1)
        XCTAssertTrue(hostedSubviews.first === controller.surface.view)
#elseif os(macOS)
        let container = ViewportPresentingView.ContainerView(frame: .zero)
        container.host(controller.surface.view)

        // Ensure we're hosting the raw render surface view, not an NSHostingView wrapper.
        let hostedSubviews = container.subviews
        XCTAssertEqual(hostedSubviews.count, 1)
        XCTAssertTrue(hostedSubviews.first === controller.surface.view)
#else
        throw XCTSkip("Viewport hosting inspection is only available on iOS and macOS")
#endif
    }

    func testContainerHostsMetalRenderSurfaceInSwiftUIHierarchy() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal not available - skipping GPU-dependent test")

        let controller = try VolumeViewportController()
        let view = VolumeViewportContainer(controller: controller)
#if os(iOS)
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
#elseif os(macOS)
        withExtendedLifetime(view) {}
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKUI/VolumeViewportContainer.swift"))

        XCTAssertTrue(source.contains("MetalViewportView(surface: controller.surface)"))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("VolumetricRenderSurface")"#))
#else
        throw XCTSkip("SwiftUI host hierarchy inspection is only available on iOS and macOS")
#endif
    }

    func testClinicalViewportGridHostsThreeMPRMetalViewportSurfaces() async throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal not available - skipping GPU-dependent test")

        let session = try await ClinicalViewportSession.make()
        let view = ClinicalViewportGrid(session: session)
#if os(iOS)
        let host = UIHostingController(rootView: view)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let renderSurfaces = findViews(withAccessibilityIdentifier: "MetalViewportSurface", in: host.view)
        XCTAssertEqual(renderSurfaces.count, 3)

        await session.shutdown()
#elseif os(macOS)
        withExtendedLifetime(view) {}
        XCTAssertTrue(session.axialSurface.view !== session.coronalSurface.view)
        XCTAssertTrue(session.axialSurface.view !== session.sagittalSurface.view)
        XCTAssertTrue(session.coronalSurface.view !== session.sagittalSurface.view)
        XCTAssertTrue(session.axialSurface.view !== session.volumeSurface.view)
        XCTAssertTrue(session.coronalSurface.view !== session.volumeSurface.view)
        XCTAssertTrue(session.sagittalSurface.view !== session.volumeSurface.view)
        XCTAssertNotEqual(session.axialViewportID, session.coronalViewportID)
        XCTAssertNotEqual(session.axialViewportID, session.sagittalViewportID)
        XCTAssertNotEqual(session.coronalViewportID, session.sagittalViewportID)

        await session.shutdown()
#else
        await session.shutdown()
        throw XCTSkip("Clinical viewport host hierarchy inspection is only available on iOS and macOS")
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

private func findViews(withAccessibilityIdentifier identifier: String, in root: UIView) -> [UIView] {
    var matches: [UIView] = root.accessibilityIdentifier == identifier ? [root] : []
    for subview in root.subviews {
        matches.append(contentsOf: findViews(withAccessibilityIdentifier: identifier, in: subview))
    }
    return matches
}
#endif

private func sourceFilePath(_ relativePath: String) -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return packageRoot.appendingPathComponent(relativePath).path
}
#endif
