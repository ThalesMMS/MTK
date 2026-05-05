import Foundation
import XCTest

final class PublicAPIContractDocumentationTests: XCTestCase {
    func testPublicAPIContractClassifiesStableExperimentalAndInternalAPIs() throws {
        let contract = try contents(of: "Architecture/PublicAPI.md")

        for requiredText in [
            "## Stable Public API",
            "## Experimental Public API",
            "## Internal Implementation Details",
            "VolumeDataset",
            "ImageData3D",
            "StackViewport",
            "VolumeViewport",
            "VolumeViewport3D",
            "ClinicalViewportSession",
            "TransferFunction",
            "VolumeLayer",
            "SurfaceMeshLayer",
            "MTLTexture",
            "MTKView",
            "CAMetalLayer",
            "MTKRenderingEngine",
            "ViewportRenderGraph",
            "VolumeResourceManager",
            "RenderPassNode",
            "OutputTexturePool"
        ] {
            XCTAssertTrue(contract.contains(requiredText), "PublicAPI.md should mention \(requiredText)")
        }
    }

    func testMainExamplesAvoidImplementationEntryPoints() throws {
        let examples = [
            "Examples/BasicVolumeRendering.swift",
            "Examples/MPRViewer.swift",
            "Examples/TriplanarMPRViewer.swift",
            "Examples/SynchronizedMPRGrid.swift",
            "Examples/DicomLoader.swift"
        ]
        let disallowedImplementationPatterns = [
            "MTKRenderingEngine(",
            "MTKRenderingEngine.",
            "ViewportRenderGraph(",
            "VolumeResourceManager(",
            "RenderPassNode(",
            "OutputTexturePool(",
            "VolumeViewportCoordinator.shared",
            "VolumeViewportController(",
            "ClinicalViewportGridController"
        ]

        for example in examples {
            let source = try contents(of: example)
            for pattern in disallowedImplementationPatterns {
                XCTAssertFalse(
                    source.contains(pattern),
                    "\(example) should use stable public viewport contracts instead of \(pattern)"
                )
            }
        }
    }

    func testEngineImplementationTypesAreNotPublicProductAPI() throws {
        let scopedDeclarations = [
            ("Sources/MTKCore/Engine/MTKRenderingEngine.swift", "package actor MTKRenderingEngine", "public actor MTKRenderingEngine"),
            ("Sources/MTKCore/Engine/ViewportRenderGraph.swift", "package struct ViewportRenderGraph", "public struct ViewportRenderGraph"),
            ("Sources/MTKCore/Engine/ViewportRenderNode.swift", "package struct ViewportRenderNode", "public struct ViewportRenderNode"),
            ("Sources/MTKCore/Engine/RenderPassNode.swift", "package struct RenderPassNode", "public struct RenderPassNode"),
            ("Sources/MTKCore/Engine/RenderPassNode.swift", "package enum RenderPassKind", "public enum RenderPassKind"),
            ("Sources/MTKCore/Engine/RenderPassNode.swift", "package enum RenderNodeDependency", "public enum RenderNodeDependency"),
            ("Sources/MTKCore/Engine/RenderRoute.swift", "package struct RenderRoute", "public struct RenderRoute"),
            ("Sources/MTKCore/Engine/RenderRouteResolver.swift", "package struct RenderRouteResolver", "public struct RenderRouteResolver"),
            ("Sources/MTKCore/Engine/RenderFrame.swift", "package struct RenderFrame", "public struct RenderFrame"),
            ("Sources/MTKCore/Engine/RenderGraphError.swift", "package enum RenderGraphError", "public enum RenderGraphError"),
            ("Sources/MTKCore/Engine/OutputTextureLease.swift", "package final class OutputTextureLease", "public final class OutputTextureLease"),
            ("Sources/MTKCore/Engine/ViewportTypes.swift", "package enum ViewportType", "public enum ViewportType"),
            ("Sources/MTKCore/Engine/ViewportTypes.swift", "package struct ViewportDescriptor", "public struct ViewportDescriptor"),
            ("Sources/MTKUI/Controllers/ClinicalViewportGridController.swift", "package let engine: MTKRenderingEngine", "public let engine: MTKRenderingEngine")
        ]

        for (path, expectedPackageScope, forbiddenPublicScope) in scopedDeclarations {
            let source = try contents(of: path)
            XCTAssertTrue(source.contains(expectedPackageScope), "\(path) should contain \(expectedPackageScope)")
            XCTAssertFalse(source.contains(forbiddenPublicScope), "\(path) should not expose \(forbiddenPublicScope)")
        }

        let presentationPass = try contents(of: "Sources/MTKCore/Rendering/PresentationPass.swift")
        XCTAssertTrue(presentationPass.contains("package func present(_ frame: VolumeRenderFrame"))
        XCTAssertTrue(presentationPass.contains("package func present(_ sourceTexture: any MTLTexture"))
        XCTAssertFalse(presentationPass.contains("public func present(_ frame: VolumeRenderFrame,\n                        to drawable: (any CAMetalDrawable)?,\n                        commandQueue: any MTLCommandQueue,\n                        lease: OutputTextureLease"))
        XCTAssertFalse(presentationPass.contains("public func present(_ sourceTexture: any MTLTexture,\n                        metadata: PresentationFrameMetadata,\n                        to drawable: (any CAMetalDrawable)?,\n                        commandQueue: any MTLCommandQueue,\n                        lease: OutputTextureLease"))

        let metalViewportSurface = try contents(of: "Sources/MTKUI/Common/MetalViewportSurface.swift")
        XCTAssertTrue(metalViewportSurface.contains("package func present(_ texture: any MTLTexture"))
        XCTAssertFalse(metalViewportSurface.contains("public func present(_ texture: any MTLTexture,\n                        metadata: PresentationFrameMetadata,\n                        lease: OutputTextureLease"))
        XCTAssertFalse(metalViewportSurface.contains("public func present(_ texture: any MTLTexture,\n                        lease: OutputTextureLease"))
    }

    private func contents(of relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
