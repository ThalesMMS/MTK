import CoreGraphics
import Foundation
@preconcurrency import Metal
import MTKCore
import MTKDicomBridge
import simd

private struct Options {
    var dicomURL: URL
    var referenceShaderURL: URL
    var frameCount: Int
    var viewportSize: Int
    var sampleStep: Float

    static func parse(arguments: [String]) throws -> Options {
        var dicomURL = firstExistingURL([
            "MTK-Demo/DICOM_Example/dicom_series_example.zip",
            "../MTK-Demo/DICOM_Example/dicom_series_example.zip"
        ])
        var referenceShaderURL = bundledReferenceShaderURL()
        var frameCount = 60
        var viewportSize = 512
        var sampleStep: Float = 1.0 / 512.0

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--dicom":
                index += 1
                dicomURL = URL(fileURLWithPath: try value(arguments, at: index, for: argument))
            case "--reference-shader":
                index += 1
                referenceShaderURL = URL(fileURLWithPath: try value(arguments, at: index, for: argument))
            case "--frames":
                index += 1
                frameCount = Int(try value(arguments, at: index, for: argument)) ?? frameCount
            case "--size":
                index += 1
                viewportSize = Int(try value(arguments, at: index, for: argument)) ?? viewportSize
            case "--sample-step":
                index += 1
                sampleStep = Float(try value(arguments, at: index, for: argument)) ?? sampleStep
            case "--help", "-h":
                throw BenchmarkError.help
            default:
                throw BenchmarkError.invalidArgument(argument)
            }
            index += 1
        }

        return Options(dicomURL: dicomURL.standardizedFileURL,
                       referenceShaderURL: referenceShaderURL.standardizedFileURL,
                       frameCount: max(1, frameCount),
                       viewportSize: max(16, viewportSize),
                       sampleStep: max(sampleStep, 1.0e-5))
    }

    private static func value(_ arguments: [String], at index: Int, for option: String) throws -> String {
        guard index < arguments.count else {
            throw BenchmarkError.missingValue(option)
        }
        return arguments[index]
    }

    private static func firstExistingURL(_ paths: [String]) -> URL {
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return URL(fileURLWithPath: paths[0]).standardizedFileURL
    }

    private static func bundledReferenceShaderURL() -> URL {
        if let url = Bundle.module.url(forResource: "ReferenceVolumeRayMarching", withExtension: "metal") {
            return url
        }
        return firstExistingURL([
            "Benchmarks/VolumeRendererComparison/ReferenceVolumeRayMarching.metal",
            "MTK/Benchmarks/VolumeRendererComparison/ReferenceVolumeRayMarching.metal"
        ])
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case help
    case invalidArgument(String)
    case missingValue(String)
    case missingFile(URL)
    case metalUnavailable
    case commandQueueUnavailable
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case textureCreationFailed(String)
    case timedOutLoadingDicom

    var description: String {
        switch self {
        case .help:
            return """
            Usage:
              swift run VolumeRendererComparison [--dicom path] [--reference-shader path] [--frames n] [--size px] [--sample-step distance]

            Defaults:
              --dicom ../MTK-Demo/DICOM_Example/dicom_series_example.zip
              --reference-shader bundled ReferenceVolumeRayMarching.metal
              --frames 60
              --size 512
              --sample-step 0.001953125
            """
        case .invalidArgument(let argument):
            return "Invalid argument: \(argument)"
        case .missingValue(let option):
            return "Missing value for \(option)"
        case .missingFile(let url):
            return "Required file does not exist: \(url.path)"
        case .metalUnavailable:
            return "Metal is unavailable on this machine."
        case .commandQueueUnavailable:
            return "Could not create Metal command queue."
        case .commandBufferUnavailable:
            return "Could not create Metal command buffer."
        case .renderEncoderUnavailable:
            return "Could not create Metal render command encoder."
        case .textureCreationFailed(let label):
            return "Could not create texture: \(label)"
        case .timedOutLoadingDicom:
            return "Timed out loading DICOM fixture."
        }
    }
}

private struct BenchmarkSummary {
    let name: String
    let frameCount: Int
    let totalMilliseconds: Double
    let averageMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let framesPerSecond: Double

    init(name: String, measurements: [Double]) {
        let sorted = measurements.sorted()
        frameCount = measurements.count
        totalMilliseconds = measurements.reduce(0, +)
        averageMilliseconds = totalMilliseconds / Double(max(measurements.count, 1))
        medianMilliseconds = percentile(sorted, 0.5)
        p95Milliseconds = percentile(sorted, 0.95)
        framesPerSecond = 1000.0 / averageMilliseconds
        self.name = name
    }
}

private struct ReferenceVolumeUniforms {
    var dimensions: SIMD3<Float>
    var stepSize: Float
    var volumeScale: SIMD3<Float>
    var yaw: Float
    var pitch: Float
    var zoom: Float
    var aspect: Float
    var slicePlaneFraction: Float
    var showSlicePlane: Float
    var backgroundMode: Float
    var padding: Float
}

private struct ReferenceRenderer {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    let pipelineState: any MTLRenderPipelineState
    let samplerState: any MTLSamplerState
    let volumeTexture: any MTLTexture
    let transferTexture: any MTLTexture
    let outputTexture: any MTLTexture
    let volumeScale: SIMD3<Float>
    let stepSize: Float

    init(device: any MTLDevice,
         commandQueue: any MTLCommandQueue,
         dataset: VolumeDataset,
         shaderURL: URL,
         viewportSize: Int) throws {
        guard FileManager.default.fileExists(atPath: shaderURL.path) else {
            throw BenchmarkError.missingFile(shaderURL)
        }

        self.device = device
        self.commandQueue = commandQueue
        pipelineState = try Self.makePipeline(device: device, shaderURL: shaderURL)
        samplerState = try Self.makeSampler(device: device)
        volumeTexture = try Self.makeVolumeTexture(device: device, dataset: dataset)
        transferTexture = try Self.makeTransferTexture(device: device)
        outputTexture = try Self.makeOutputTexture(device: device, size: viewportSize)
        volumeScale = Self.normalizedVolumeScale(for: dataset)
        stepSize = 1.0 / Float(max(dataset.dimensions.width, dataset.dimensions.height, dataset.dimensions.depth)) * 0.75
    }

    func render(yaw: Float, pitch: Float) throws -> Double {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = outputTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BenchmarkError.commandBufferUnavailable
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw BenchmarkError.renderEncoderUnavailable
        }

        var uniforms = ReferenceVolumeUniforms(
            dimensions: SIMD3<Float>(Float(volumeTexture.width), Float(volumeTexture.height), Float(volumeTexture.depth)),
            stepSize: stepSize,
            volumeScale: volumeScale,
            yaw: yaw,
            pitch: pitch,
            zoom: 1.8,
            aspect: 1,
            slicePlaneFraction: -1,
            showSlicePlane: 0,
            backgroundMode: 1,
            padding: 0
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReferenceVolumeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(transferTexture, index: 1)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return milliseconds(from: startedAt)
    }

    private static func makePipeline(device: any MTLDevice,
                                     shaderURL: URL) throws -> any MTLRenderPipelineState {
        let source = try String(contentsOf: shaderURL)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "volumeVertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "volumeFragmentMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeSampler(device: any MTLDevice) throws -> any MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.rAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw BenchmarkError.textureCreationFailed("reference sampler")
        }
        return sampler
    }

    private static func makeVolumeTexture(device: any MTLDevice,
                                          dataset: VolumeDataset) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Float
        descriptor.width = dataset.dimensions.width
        descriptor.height = dataset.dimensions.height
        descriptor.depth = dataset.dimensions.depth
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BenchmarkError.textureCreationFailed("reference volume")
        }

        let values = dataset.data.withUnsafeBytes { rawBuffer -> [Float16] in
            let source = rawBuffer.bindMemory(to: Int16.self)
            return source.map { Float16(Float($0)) }
        }
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, descriptor.width, descriptor.height, descriptor.depth),
                            mipmapLevel: 0,
                            slice: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: descriptor.width * MemoryLayout<Float16>.stride,
                            bytesPerImage: descriptor.width * descriptor.height * MemoryLayout<Float16>.stride)
        }
        return texture
    }

    private static func makeTransferTexture(device: any MTLDevice) throws -> any MTLTexture {
        let table = softTissueTransferTable(sampleCount: 1024)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                                  width: table.count,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BenchmarkError.textureCreationFailed("reference transfer")
        }
        table.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, table.count, 1),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: table.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        return texture
    }

    private static func makeOutputTexture(device: any MTLDevice,
                                          size: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BenchmarkError.textureCreationFailed("reference output")
        }
        return texture
    }

    private static func normalizedVolumeScale(for dataset: VolumeDataset) -> SIMD3<Float> {
        let bounds = SIMD3<Float>(
            Float(max(dataset.dimensions.width - 1, 0)) * Float(dataset.spacing.x),
            Float(max(dataset.dimensions.height - 1, 0)) * Float(dataset.spacing.y),
            Float(max(dataset.dimensions.depth - 1, 0)) * Float(dataset.spacing.z)
        )
        let extents = SIMD3<Float>(
            bounds.x > 0 ? bounds.x : max(Float(dataset.spacing.x), 1),
            bounds.y > 0 ? bounds.y : max(Float(dataset.spacing.y), 1),
            bounds.z > 0 ? bounds.z : max(Float(dataset.spacing.z), 1)
        )
        let longest = max(max(extents.x, extents.y), max(extents.z, 0.0001))
        return SIMD3<Float>(
            max(extents.x / longest, 0.001),
            max(extents.y / longest, 0.001),
            max(extents.z / longest, 0.001)
        )
    }
}

@main
private enum VolumeRendererComparison {
    static func main() async {
        do {
            let options = try Options.parse(arguments: CommandLine.arguments)
            let summary = try await run(options: options)
            print(summary)
        } catch BenchmarkError.help {
            print(BenchmarkError.help.description)
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(options: Options) async throws -> String {
        guard FileManager.default.fileExists(atPath: options.dicomURL.path) else {
            throw BenchmarkError.missingFile(options.dicomURL)
        }
        guard FileManager.default.fileExists(atPath: options.referenceShaderURL.path) else {
            throw BenchmarkError.missingFile(options.referenceShaderURL)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchmarkError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw BenchmarkError.commandQueueUnavailable
        }

        let importStartedAt = CFAbsoluteTimeGetCurrent()
        let dataset = try loadDicomDataset(from: options.dicomURL, device: device)
        let importMilliseconds = milliseconds(from: importStartedAt)
        let rotations = makeRotations(count: options.frameCount)

        let transfer = softTissueVolumeTransferFunction()
        let adapter = try MetalVolumeRenderingAdapter(device: device)
        try await adapter.setHuWindow(min: -1200, max: 3000)
        let baseRequest = VolumeRenderRequest(
            dataset: dataset,
            transferFunction: transfer,
            viewportSize: CGSize(width: options.viewportSize, height: options.viewportSize),
            camera: makeMTKCamera(yaw: 0, pitch: 0),
            samplingDistance: options.sampleStep,
            compositing: .frontToBack,
            quality: .interactive
        )
        _ = try await adapter.renderInteractiveTexture(using: baseRequest)
        let mtkMeasurements = try await rotations.mapAsync { yaw, pitch in
            var request = baseRequest
            request.camera = makeMTKCamera(yaw: yaw, pitch: pitch)
            let startedAt = CFAbsoluteTimeGetCurrent()
            _ = try await adapter.renderInteractiveTexture(using: request)
            return milliseconds(from: startedAt)
        }

        let referenceRenderer = try ReferenceRenderer(device: device,
                                                      commandQueue: commandQueue,
                                                      dataset: dataset,
                                                      shaderURL: options.referenceShaderURL,
                                                      viewportSize: options.viewportSize)
        _ = try referenceRenderer.render(yaw: 0, pitch: 0)
        let referenceMeasurements = try rotations.map { yaw, pitch in
            try referenceRenderer.render(yaw: yaw, pitch: pitch)
        }

        let mtk = BenchmarkSummary(name: "MTK", measurements: mtkMeasurements)
        let reference = BenchmarkSummary(name: "Reference", measurements: referenceMeasurements)
        let fpsRatio = mtk.framesPerSecond / max(reference.framesPerSecond, 0.0001)
        let verdict = fpsRatio >= 1 ? "PASS" : "FAIL"

        return """
        Volume renderer comparison
        device: \(device.name)
        dicom: \(options.dicomURL.path)
        referenceShader: \(options.referenceShaderURL.path)
        dataset: \(dataset.dimensions.width)x\(dataset.dimensions.height)x\(dataset.dimensions.depth), spacing=\(format(dataset.spacing.x))x\(format(dataset.spacing.y))x\(format(dataset.spacing.z)), importMs=\(format(importMilliseconds))
        frames: \(options.frameCount), viewport: \(options.viewportSize)x\(options.viewportSize), mtkSampleStep=\(format(Double(options.sampleStep))), referenceSampleStep=\(format(Double(referenceRenderer.stepSize)))

        \(line(for: mtk))
        \(line(for: reference))
        ratio: MTK/reference fps=\(format(fpsRatio)) verdict=\(verdict)
        """
    }
}

private func loadDicomDataset(from url: URL, device: any MTLDevice) throws -> VolumeDataset {
    let loader = DicomVolumeLoader(device: device)
    var captured: Result<DicomImportResult, any Error>?
    loader.loadVolume(from: url, progress: { _ in }) { result in
        captured = result
    }

    let deadline = Date().addingTimeInterval(120)
    while captured == nil && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }

    guard let captured else {
        throw BenchmarkError.timedOutLoadingDicom
    }
    return try captured.get().dataset
}

private func makeMTKCamera(yaw: Float, pitch: Float) -> VolumeRenderRequest.Camera {
    let offset = rotate(SIMD3<Float>(0, 0, 1.8), yaw: yaw, pitch: pitch)
    let up = rotate(SIMD3<Float>(0, 1, 0), yaw: yaw, pitch: pitch)
    let target = SIMD3<Float>(repeating: 0.5)
    return VolumeRenderRequest.Camera(position: target + offset,
                                      target: target,
                                      up: simd_normalize(up),
                                      fieldOfView: 60,
                                      projectionType: .perspective)
}

private func rotate(_ value: SIMD3<Float>, yaw: Float, pitch: Float) -> SIMD3<Float> {
    let yawRotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    let pitchRotation = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    return yawRotation.act(pitchRotation.act(value))
}

private func makeRotations(count: Int) -> [(Float, Float)] {
    (0..<count).map { index in
        let t = Float(index) / Float(max(count - 1, 1))
        return (t * .pi * 0.75, sin(t * .pi * 2) * 0.35)
    }
}

private func softTissueVolumeTransferFunction() -> VolumeTransferFunction {
    VolumeTransferFunction(
        opacityPoints: softTissueTransferPoints().map {
            VolumeTransferFunction.OpacityControlPoint(intensity: $0.hu, opacity: $0.opacity)
        },
        colourPoints: softTissueTransferPoints().map {
            VolumeTransferFunction.ColourControlPoint(intensity: $0.hu,
                                                      colour: SIMD4<Float>($0.color.x, $0.color.y, $0.color.z, 1))
        }
    )
}

private func softTissueTransferTable(sampleCount: Int) -> [SIMD4<Float>] {
    let lowerHU: Float = -1200
    let upperHU: Float = 3000
    let points = softTissueTransferPoints().sorted { $0.hu < $1.hu }

    return (0..<sampleCount).map { index in
        let t = Float(index) / Float(max(sampleCount - 1, 1))
        let hu = lowerHU + (upperHU - lowerHU) * t
        let point = interpolatedTransferPoint(hu: hu, points: points)
        return SIMD4<Float>(point.color.x, point.color.y, point.color.z, point.opacity)
    }
}

private func softTissueTransferPoints() -> [(hu: Float, color: SIMD3<Float>, opacity: Float)] {
    [
        (-1000, SIMD3<Float>(0, 0, 0), 0),
        (-150, SIMD3<Float>(0.45, 0.22, 0.16), 0.02),
        (40, SIMD3<Float>(0.85, 0.52, 0.42), 0.18),
        (300, SIMD3<Float>(1.0, 0.82, 0.68), 0.35),
        (1200, SIMD3<Float>(1.0, 0.95, 0.88), 0.45)
    ]
}

private func interpolatedTransferPoint(hu: Float,
                                       points: [(hu: Float, color: SIMD3<Float>, opacity: Float)])
    -> (color: SIMD3<Float>, opacity: Float) {
    guard let first = points.first, let last = points.last else {
        return (SIMD3<Float>(repeating: 0), 0)
    }
    if hu <= first.hu {
        return (first.color, first.opacity)
    }
    if hu >= last.hu {
        return (last.color, last.opacity)
    }
    for index in 0..<(points.count - 1) {
        let a = points[index]
        let b = points[index + 1]
        guard hu >= a.hu && hu <= b.hu else { continue }
        let local = (hu - a.hu) / max(b.hu - a.hu, 0.001)
        return (a.color + (b.color - a.color) * local,
                a.opacity + (b.opacity - a.opacity) * local)
    }
    return (SIMD3<Float>(repeating: 0), 0)
}

private func line(for summary: BenchmarkSummary) -> String {
    "\(summary.name): fps=\(format(summary.framesPerSecond)) avgMs=\(format(summary.averageMilliseconds)) medianMs=\(format(summary.medianMilliseconds)) p95Ms=\(format(summary.p95Milliseconds)) frames=\(summary.frameCount)"
}

private func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
    guard !sortedValues.isEmpty else { return 0 }
    let index = Int((Double(sortedValues.count - 1) * p).rounded())
    return sortedValues[min(max(index, 0), sortedValues.count - 1)]
}

private func milliseconds(from start: CFAbsoluteTime,
                          to end: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
    max(0, (end - start) * 1000.0)
}

private func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private extension Array {
    func mapAsync<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
