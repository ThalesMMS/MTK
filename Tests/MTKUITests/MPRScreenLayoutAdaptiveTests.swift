//
//  MPRScreenLayoutAdaptiveTests.swift
//  MTKUITests
//
//  Layout-calculation coverage for the large-screen MPR presets and the
//  ViewerLayoutClass recommendations (issue #1214). GPU-free.
//

import CoreGraphics
import XCTest
@testable import MTKUI

final class MPRScreenLayoutAdaptiveTests: XCTestCase {

    private let divider = MPRViewportGridLayoutCalculator.dividerThickness

    private func layout(
        _ screenLayout: MPRScreenLayout,
        width: CGFloat,
        height: CGFloat,
        verticalSplit: CGFloat = 0.5,
        horizontalSplit: CGFloat = 0.5,
        fullscreenSlot: Int? = nil
    ) -> MPRViewportGridLayout {
        MPRViewportGridLayoutCalculator.layout(
            for: screenLayout,
            totalWidth: width,
            totalHeight: height,
            verticalSplit: verticalSplit,
            horizontalSplit: horizontalSplit,
            fullscreenSlot: fullscreenSlot
        )
    }

    private func assertNoOverlap(_ layout: MPRViewportGridLayout, file: StaticString = #filePath, line: UInt = #line) {
        let rects = [layout.rect1, layout.rect2, layout.rect3]
        for (index, lhs) in rects.enumerated() {
            for rhs in rects.dropFirst(index + 1) {
                XCTAssertFalse(
                    lhs.insetBy(dx: 0.5, dy: 0.5).intersects(rhs.insetBy(dx: 0.5, dy: 0.5)),
                    "panes overlap: \(lhs) vs \(rhs)", file: file, line: line
                )
            }
        }
    }

    // MARK: - primaryLeft (tablet/desktop)

    func test_primaryLeft_iPadLandscape_primaryPaneSpansFullHeight() {
        let result = layout(.primaryLeft, width: 1024, height: 768, horizontalSplit: 0.6)

        XCTAssertEqual(result.rect1.minX, 0)
        XCTAssertEqual(result.rect1.height, 768)
        XCTAssertEqual(result.rect1.width, 1024 * 0.6 - divider / 2, accuracy: 0.5)

        // Secondaries stack on the right of the vertical divider.
        XCTAssertEqual(result.rect2.minX, result.rect1.maxX + divider, accuracy: 0.5)
        XCTAssertEqual(result.rect3.minX, result.rect2.minX)
        XCTAssertGreaterThan(result.rect3.minY, result.rect2.maxY)

        // Both dividers stay draggable: one vertical + one horizontal.
        XCTAssertEqual(result.dividers.count, 2)
        assertNoOverlap(result)
    }

    func test_primaryLeft_respectsVerticalSplitForSecondaryStack() {
        let result = layout(.primaryLeft, width: 1280, height: 800, verticalSplit: 0.7)

        XCTAssertEqual(result.rect2.height, 800 * 0.7 - divider / 2, accuracy: 0.5)
        XCTAssertEqual(result.rect3.height, 800 * 0.3 - divider / 2, accuracy: 0.5)
    }

    // MARK: - vSplit1x3 (desktop)

    func test_threeColumns_desktopWindow_columnsAreEqualAndFullHeight() {
        let result = layout(.vSplit1x3, width: 1280, height: 800)

        let expectedColumn = (1280 - divider * 2) / 3
        for rect in [result.rect1, result.rect2, result.rect3] {
            XCTAssertEqual(rect.width, expectedColumn, accuracy: 0.5)
            XCTAssertEqual(rect.height, 800)
            XCTAssertEqual(rect.minY, 0)
        }
        XCTAssertEqual(result.rect2.minX, result.rect1.maxX + divider, accuracy: 0.5)
        XCTAssertEqual(result.rect3.minX, result.rect2.maxX + divider, accuracy: 0.5)
        XCTAssertEqual(result.dividers.count, 2)
        assertNoOverlap(result)
    }

    // MARK: - Fullscreen slot stays correct for new layouts

    func test_fullscreenSlot_overridesNewLayouts() {
        for screenLayout in [MPRScreenLayout.primaryLeft, .vSplit1x3] {
            for slot in 1...3 {
                let result = layout(screenLayout, width: 1024, height: 768, fullscreenSlot: slot)
                let full = CGRect(x: 0, y: 0, width: 1024, height: 768)
                let rects = [result.rect1, result.rect2, result.rect3]
                XCTAssertEqual(rects[slot - 1], full, "\(screenLayout) slot \(slot)")
                XCTAssertTrue(result.dividers.isEmpty)
                XCTAssertEqual(rects.filter { $0 == .zero }.count, 2)
            }
        }
    }

    // MARK: - Source compatibility and recommendations

    func test_existingLayouts_remainUnchanged() {
        // Historical hSplit1x2 geometry must not move (source/visual
        // compatibility with existing consumers).
        let result = layout(.hSplit1x2, width: 800, height: 600)
        XCTAssertEqual(result.rect1, CGRect(x: 0, y: 0, width: 800, height: 600 * 0.5 - divider / 2))
        XCTAssertEqual(MPRScreenLayout.defaultLayout, .hSplit1x2)
    }

    func test_recommendedLayouts_perLayoutClass() {
        XCTAssertEqual(MPRScreenLayout.recommendedLayouts(for: .compactPhone), MPRScreenLayout.compactLayouts)
        XCTAssertEqual(MPRScreenLayout.recommendedLayouts(for: .compactTablet), MPRScreenLayout.compactLayouts)
        XCTAssertEqual(
            MPRScreenLayout.recommendedLayouts(for: .tablet),
            MPRScreenLayout.compactLayouts + [.primaryLeft]
        )
        XCTAssertEqual(
            MPRScreenLayout.recommendedLayouts(for: .desktop),
            MPRScreenLayout.compactLayouts + [.primaryLeft, .vSplit1x3]
        )
        // Large-screen recommendations must never collapse back to the
        // compact-only set (regression guard, issues #1214/#1215).
        XCTAssertGreaterThan(MPRScreenLayout.recommendedLayouts(for: .tablet).count, MPRScreenLayout.compactLayouts.count)
        XCTAssertGreaterThan(MPRScreenLayout.recommendedLayouts(for: .desktop).count, MPRScreenLayout.recommendedLayouts(for: .tablet).count)
    }

    func test_titlesAndIdentifiers_forNewLayouts() {
        XCTAssertFalse(MPRScreenLayout.primaryLeft.title.isEmpty)
        XCTAssertFalse(MPRScreenLayout.vSplit1x3.title.isEmpty)
        XCTAssertEqual(MPRScreenLayout.primaryLeft.accessibilityIdentifier, "MPRScreenLayout.primaryLeft")
        XCTAssertTrue(MPRScreenLayout.allCases.contains(.primaryLeft))
        XCTAssertTrue(MPRScreenLayout.allCases.contains(.vSplit1x3))
    }
}
