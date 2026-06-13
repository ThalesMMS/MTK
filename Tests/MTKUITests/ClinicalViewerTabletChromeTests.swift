//
//  ClinicalViewerTabletChromeTests.swift
//  MTKUITests
//
//  Structural coverage for the tablet chrome (issue #1211): dock
//  presentation per layout class and touch-target metrics, no GPU needed.
//

import SwiftUI
import XCTest
@testable import MTKUI

final class ClinicalViewerTabletChromeTests: XCTestCase {

    func test_dockPresentation_perLayoutClass() {
        XCTAssertEqual(TabletChromeDockPresentation.presentation(for: .tablet), .sideDock)
        XCTAssertEqual(TabletChromeDockPresentation.presentation(for: .desktop), .sideDock)
        XCTAssertEqual(TabletChromeDockPresentation.presentation(for: .compactTablet), .bottomDock)
        XCTAssertEqual(TabletChromeDockPresentation.presentation(for: .compactPhone), .bottomDock)
    }

    func test_metrics_areTouchFriendly() {
        XCTAssertGreaterThanOrEqual(TabletChromeMetrics.controlHitTarget, 44)
        XCTAssertGreaterThanOrEqual(TabletChromeMetrics.sideDockWidth, 280)
        XCTAssertLessThanOrEqual(
            TabletChromeMetrics.bottomDockMaxHeight, 320,
            "bottom dock must not obscure the diagnostic viewport"
        )
    }

    @MainActor
    func test_chrome_buildsForRepresentativeWidths() {
        // Construction-level smoke test: the chrome body must be buildable
        // for every layout class without a viewer session or GPU.
        for layoutClass in ViewerLayoutClass.allCases {
            let chrome = ClinicalViewerTabletChrome(
                title: "Preview",
                mode: .clinical,
                onSelectMode: { _ in },
                content: { Color.black },
                dock: { Text("Dock") }
            )
            .viewerLayoutClass(layoutClass)

            let host = _makeHostingController(rootView: AnyView(chrome))
            XCTAssertNotNil(host.view, "chrome failed to build for \(layoutClass)")
        }
    }
}

@MainActor
private func _makeHostingController(rootView: AnyView) -> PlatformHostingController {
    PlatformHostingController(rootView: rootView)
}

#if os(iOS)
private typealias PlatformHostingController = UIHostingController<AnyView>
#else
private typealias PlatformHostingController = NSHostingController<AnyView>
#endif
