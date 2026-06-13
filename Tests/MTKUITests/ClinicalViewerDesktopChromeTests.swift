//
//  ClinicalViewerDesktopChromeTests.swift
//  MTKUITests
//
//  Structural coverage for the desktop chrome and command model
//  (issue #1212), GPU-free.
//

import SwiftUI
import XCTest
@testable import MTKUI

final class ViewerCommandDescriptorTests: XCTestCase {

    func test_defaultCommands_haveUniqueIDsAndTitles() {
        let commands = ViewerCommandDescriptor.defaultViewerCommands
        XCTAssertEqual(commands.count, Set(commands.map(\.id)).count)
        for command in commands {
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertFalse(command.systemImage.isEmpty)
        }
    }

    func test_defaultCommands_keyEquivalentsDoNotCollide() {
        let commands = ViewerCommandDescriptor.defaultViewerCommands
        let combos = commands.compactMap { command -> String? in
            guard let key = command.key else { return nil }
            return "\(command.modifiers.rawValue)+\(key)"
        }
        XCTAssertEqual(combos.count, Set(combos).count, "conflicting default shortcuts")
    }

    func test_modeCommands_mapToViewerModes() {
        XCTAssertEqual(
            ViewerCommandDescriptor.defaultViewerCommands.first { $0.id == .switchTo2D }?.targetMode,
            .stack2D
        )
        XCTAssertEqual(
            ViewerCommandDescriptor.defaultViewerCommands.first { $0.id == .switchToMPR }?.targetMode,
            .clinical
        )
        XCTAssertEqual(
            ViewerCommandDescriptor.defaultViewerCommands.first { $0.id == .switchTo3D }?.targetMode,
            .single3D
        )
        XCTAssertNil(
            ViewerCommandDescriptor.defaultViewerCommands.first { $0.id == .resetView }?.targetMode
        )
    }

    func test_keyboardShortcut_bridgesKeyAndModifiers() {
        let descriptor = ViewerCommandDescriptor(
            id: .exportSnapshot, title: "Export", systemImage: "camera",
            key: "e", modifiers: [.command, .shift]
        )
        XCTAssertNotNil(descriptor.keyboardShortcut)
        XCTAssertTrue(descriptor.modifiers.eventModifiers.contains(.command))
        XCTAssertTrue(descriptor.modifiers.eventModifiers.contains(.shift))

        let bare = ViewerCommandDescriptor(id: .resetView, title: "Reset", systemImage: "arrow.counterclockwise")
        XCTAssertNil(bare.keyboardShortcut)
    }
}

final class ClinicalViewerDesktopChromeTests: XCTestCase {

    func test_metrics() {
        XCTAssertGreaterThanOrEqual(DesktopChromeMetrics.inspectorWidth, 260)
        XCTAssertGreaterThanOrEqual(DesktopChromeMetrics.toolbarHeight, 36)
    }

    @MainActor
    func test_chrome_buildsWithoutGPU() {
        let chrome = ClinicalViewerDesktopChrome(
            mode: .clinical,
            onCommand: { _ in },
            content: { Color.black },
            inspector: {
                ViewerInspectorSection("Tools") { Text("Tools") }
            }
        )
        let host = PlatformChromeHostingController(rootView: AnyView(chrome))
        XCTAssertNotNil(host.view)
    }

    @MainActor
    func test_toolbar_dispatchesCommandIDs() {
        var received: [ViewerCommandID] = []
        let toolbar = ViewerDesktopToolbar(activeMode: .clinical) { received.append($0) }
        // Dispatch closure is exercised directly: rendering hit-testing is
        // out of scope without a UI host, but the wiring stays covered.
        toolbar.simulateCommand(.resetView)
        toolbar.simulateCommand(.switchTo3D)
        XCTAssertEqual(received, [.resetView, .switchTo3D])
    }
}

extension ViewerDesktopToolbar {
    /// Test hook: dispatches a command through the toolbar's callback.
    func simulateCommand(_ id: ViewerCommandID) {
        onCommandForTesting(id)
    }
}

#if os(iOS)
private typealias PlatformChromeHostingController = UIHostingController<AnyView>
#else
private typealias PlatformChromeHostingController = NSHostingController<AnyView>
#endif
