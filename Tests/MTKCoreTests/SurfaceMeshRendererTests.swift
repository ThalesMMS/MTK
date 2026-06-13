import Metal
import simd
import XCTest

@testable import MTKCore

final class SurfaceMeshRendererTests: XCTestCase {
    func testSurfaceMeshLookAtMatchesCanonicalMatrixForObliqueCamera() throws {
        let eye = SIMD3<Float>(1.25, -0.75, 2.5)
        let target = SIMD3<Float>(-0.2, 0.1, 0.3)
        let up = simd_normalize(SIMD3<Float>(0.2, 1, 0.1))

        let actual = try simd_float4x4(surfaceMeshLookAt: eye, target: target, up: up)
        let expected = canonicalLookAt(eye: eye, target: target, up: up)

        assertMatrix(actual, expected)
    }

    func testSurfaceMeshLookAtKeepsAxisAlignedDefaultCameraMatrix() throws {
        let actual = try simd_float4x4(surfaceMeshLookAt: SIMD3<Float>(0, 0, 1.5),
                                       target: .zero,
                                       up: SIMD3<Float>(0, 1, 0))
        let expected = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, -1.5, 1)
        ))

        assertMatrix(actual, expected)
    }

    func testRendererDrawsSimpleSurfaceMeshIntoTexture() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            pixelFormat: .int16Signed
        )
        let mesh = SurfaceMesh(
            name: "Triangle",
            vertices: [
                SIMD3<Float>(0.25, 0.25, 0.5),
                SIMD3<Float>(0.75, 0.25, 0.5),
                SIMD3<Float>(0.5, 0.75, 0.5)
            ],
            normals: [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1)
            ],
            indices: [0, 1, 2],
            coordinateSpace: .textureNormalized
        )
        let layer = SurfaceMeshLayer(mesh: mesh,
                                     material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1)))
        let camera = VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, 0.5, 2),
                                                target: SIMD3<Float>(repeating: 0.5),
                                                up: SIMD3<Float>(0, 1, 0),
                                                fieldOfView: 45)

        try await renderer.render(layers: [layer],
                                  dataset: dataset,
                                  camera: camera,
                                  targetTexture: target,
                                  clearTarget: true)

        let bytes = try MPRTextureReadbackHelper.readBytes(from: target,
                                                           bytesPerPixel: 4,
                                                           device: device,
                                                           commandQueue: queue)
        let hasColoredPixel = stride(from: 0, to: bytes.count, by: 4).contains { offset in
            bytes[offset] > 0 || bytes[offset + 1] > 0 || bytes[offset + 2] > 0
        }
        XCTAssertTrue(hasColoredPixel)
    }

    func testOpaqueFrontSurfaceWinsDepthEvenWhenDrawnBeforeBackSurface() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let dataset = makeDataset()
        let front = SurfaceMeshLayer(
            id: "front",
            mesh: makeQuadMesh(z: 0.75),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1))
        )
        let back = SurfaceMeshLayer(
            id: "back",
            mesh: makeQuadMesh(z: 0.25),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(0, 0, 1, 1))
        )

        try await renderer.render(layers: [front, back],
                                  dataset: dataset,
                                  camera: makeCamera(),
                                  targetTexture: target,
                                  clearTarget: true)

        let pixel = try centerPixel(from: target, device: device, commandQueue: queue)
        XCTAssertGreaterThan(pixel.r, pixel.b)
        XCTAssertGreaterThan(pixel.r, 20)
    }

    func testSurfaceClippingUsesVolumeCropBounds() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let dataset = makeDataset()
        let layer = SurfaceMeshLayer(
            id: "cropped-away",
            mesh: makeQuadMesh(z: 0.75),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1))
        )
        let clipping = try VolumeClippingState(cropBox: VolumeCropBox(
            textureMin: .zero,
            textureMax: SIMD3<Float>(1, 1, 0.5)
        ))

        try await renderer.render(layers: [layer],
                                  dataset: dataset,
                                  camera: makeCamera(),
                                  targetTexture: target,
                                  clipping: clipping,
                                  clearTarget: true)

        let bytes = try MPRTextureReadbackHelper.readBytes(from: target,
                                                           bytesPerPixel: 4,
                                                           device: device,
                                                           commandQueue: queue)
        let hasVisibleRGB = stride(from: 0, to: bytes.count, by: 4).contains { offset in
            bytes[offset] > 5 || bytes[offset + 1] > 5 || bytes[offset + 2] > 5
        }
        XCTAssertFalse(hasVisibleRGB)
    }

    func testSurfaceClippingUsesClipPlanes() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let dataset = makeDataset()
        let layer = SurfaceMeshLayer(
            id: "clipped-away",
            mesh: makeQuadMesh(z: 0.75),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1))
        )
        let plane = try VolumeClipPlane(textureCenteredNormal: SIMD3<Float>(0, 0, 1),
                                        offset: 0,
                                        dataset: dataset)
        let clipping = try VolumeClippingState(clipPlanes: [plane])

        try await renderer.render(layers: [layer],
                                  dataset: dataset,
                                  camera: makeCamera(),
                                  targetTexture: target,
                                  clipping: clipping,
                                  clearTarget: true)

        let bytes = try MPRTextureReadbackHelper.readBytes(from: target,
                                                           bytesPerPixel: 4,
                                                           device: device,
                                                           commandQueue: queue)
        let hasVisibleRGB = stride(from: 0, to: bytes.count, by: 4).contains { offset in
            bytes[offset] > 5 || bytes[offset + 1] > 5 || bytes[offset + 2] > 5
        }
        XCTAssertFalse(hasVisibleRGB)
    }

    func testSemiTransparentSurfaceBlendsWithExistingTarget() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let layer = SurfaceMeshLayer(
            id: "transparent",
            mesh: makeQuadMesh(z: 0.5),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(0, 1, 0, 1)),
            opacity: 0.5
        )

        try await renderer.render(layers: [layer],
                                  dataset: makeDataset(),
                                  camera: makeCamera(),
                                  targetTexture: target,
                                  clearTarget: true)

        let pixel = try centerPixel(from: target, device: device, commandQueue: queue)
        XCTAssertGreaterThan(pixel.g, 10)
        XCTAssertLessThan(pixel.g, 220)
    }

    func testTransparentSurfacesAreLayerSortedBackToFront() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let near = SurfaceMeshLayer(
            id: "near",
            mesh: makeQuadMesh(z: 0.75),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(1, 0, 0, 1)),
            opacity: 0.5
        )
        let far = SurfaceMeshLayer(
            id: "far",
            mesh: makeQuadMesh(z: 0.25),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(0, 0, 1, 1)),
            opacity: 0.5
        )

        try await renderer.render(layers: [near, far],
                                  dataset: makeDataset(),
                                  camera: makeCamera(),
                                  targetTexture: target,
                                  clearTarget: true)

        let pixel = try centerPixel(from: target, device: device, commandQueue: queue)
        XCTAssertGreaterThan(pixel.r, pixel.b)
    }

    func testUnlitSurfaceMaterialBypassesDirectionalShading() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let layer = SurfaceMeshLayer(
            id: "unlit",
            mesh: makeQuadMesh(z: 0.5),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(0, 1, 0, 1),
                                          shading: .unlit)
        )

        try await renderer.render(layers: [layer],
                                  dataset: makeDataset(),
                                  camera: makeCamera(),
                                  targetTexture: target,
                                  clearTarget: true)

        let pixel = try centerPixel(from: target, device: device, commandQueue: queue)
        XCTAssertGreaterThan(pixel.g, 220)
    }

    func testRendererReusesStaticMeshBuffersAndDepthTextureAcrossCameraFrames() async throws {
        let device = try makeTestMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }
        let renderer = try MetalSurfaceMeshRenderer(device: device, commandQueue: queue)
        let target = try makeRenderTarget(device: device, width: 64, height: 64)
        let dataset = makeDataset()
        let layer = SurfaceMeshLayer(
            id: "static",
            mesh: makeQuadMesh(z: 0.5),
            material: SurfaceMeshMaterial(color: SIMD4<Float>(0, 1, 0, 1))
        )
        let firstCamera = makeCamera()
        let secondCamera = VolumeRenderRequest.Camera(position: SIMD3<Float>(0.4, 0.5, 2),
                                                      target: SIMD3<Float>(repeating: 0.5),
                                                      up: SIMD3<Float>(0, 1, 0),
                                                      fieldOfView: 45,
                                                      projectionType: .orthographic)

        try await renderer.render(layers: [layer],
                                  dataset: dataset,
                                  camera: firstCamera,
                                  targetTexture: target,
                                  clearTarget: true)
        try await renderer.render(layers: [layer],
                                  dataset: dataset,
                                  camera: secondCamera,
                                  targetTexture: target,
                                  clearTarget: true)

        XCTAssertEqual(renderer.debugDrawBufferRebuildCount, 1)
        XCTAssertEqual(renderer.debugDepthTextureAllocationCount, 1)
    }

    private func makeRenderTarget(device: any MTLDevice,
                                  width: Int,
                                  height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to allocate surface mesh render target")
        }
        return texture
    }

    private func makeDataset() -> VolumeDataset {
        VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            pixelFormat: .int16Signed
        )
    }

    private func makeCamera() -> VolumeRenderRequest.Camera {
        VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, 0.5, 2),
                                   target: SIMD3<Float>(repeating: 0.5),
                                   up: SIMD3<Float>(0, 1, 0),
                                   fieldOfView: 45,
                                   projectionType: .orthographic)
    }

    private func makeQuadMesh(z: Float) -> SurfaceMesh {
        SurfaceMesh(
            name: "Quad \(z)",
            vertices: [
                SIMD3<Float>(0.2, 0.2, z),
                SIMD3<Float>(0.8, 0.2, z),
                SIMD3<Float>(0.8, 0.8, z),
                SIMD3<Float>(0.2, 0.8, z)
            ],
            normals: [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1)
            ],
            indices: [0, 1, 2, 0, 2, 3],
            coordinateSpace: .textureNormalized
        )
    }

    private func canonicalLookAt(eye: SIMD3<Float>,
                                 target: SIMD3<Float>,
                                 up: SIMD3<Float>) -> simd_float4x4 {
        let zAxis = simd_normalize(eye - target)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        let translation = SIMD3<Float>(
            -simd_dot(xAxis, eye),
            -simd_dot(yAxis, eye),
            -simd_dot(zAxis, eye)
        )
        return simd_float4x4(columns: (
            SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
            SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
            SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    private func assertMatrix(_ actual: simd_float4x4,
                              _ expected: simd_float4x4,
                              accuracy: Float = 1e-5,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        for column in 0..<4 {
            XCTAssertEqual(actual[column].x, expected[column].x, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual[column].y, expected[column].y, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual[column].z, expected[column].z, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(actual[column].w, expected[column].w, accuracy: accuracy, file: file, line: line)
        }
    }

    private func centerPixel(from texture: any MTLTexture,
                             device: any MTLDevice,
                             commandQueue: any MTLCommandQueue) throws -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let bytes = try MPRTextureReadbackHelper.readBytes(from: texture,
                                                           bytesPerPixel: 4,
                                                           device: device,
                                                           commandQueue: commandQueue)
        let offset = ((texture.height / 2) * texture.width + (texture.width / 2)) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
}
