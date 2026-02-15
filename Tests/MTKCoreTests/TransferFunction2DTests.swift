import XCTest
import Metal
@testable import MTKCore

final class TransferFunction2DTests: XCTestCase {

    // MARK: - Model Initialization Tests

    func testDefaultInitialization() {
        let tf = TransferFunction2D()

        XCTAssertEqual(tf.name, "")
        XCTAssertTrue(tf.colourPoints.isEmpty)
        XCTAssertTrue(tf.alphaPoints.isEmpty)
        XCTAssertEqual(tf.minimumIntensity, -1024)
        XCTAssertEqual(tf.maximumIntensity, 3071)
        XCTAssertEqual(tf.minimumGradient, 0)
        XCTAssertEqual(tf.maximumGradient, 100)
        XCTAssertEqual(tf.shift, 0)
        XCTAssertEqual(tf.colorSpace, .linear)
        XCTAssertEqual(tf.intensityResolution, 256)
        XCTAssertEqual(tf.gradientResolution, 256)
    }

    func testColorPoint2DInitialization() {
        let point = TransferFunction2D.ColorPoint2D(
            intensity: 512,
            gradientMagnitude: 50,
            colourValue: TransferFunction.RGBAColor(r: 1, g: 0.5, b: 0, a: 1)
        )

        XCTAssertEqual(point.intensity, 512)
        XCTAssertEqual(point.gradientMagnitude, 50)
        XCTAssertEqual(point.colourValue.r, 1)
        XCTAssertEqual(point.colourValue.g, 0.5)
        XCTAssertEqual(point.colourValue.b, 0)
        XCTAssertEqual(point.colourValue.a, 1)
    }

    func testAlphaPoint2DInitialization() {
        let point = TransferFunction2D.AlphaPoint2D(
            intensity: 256,
            gradientMagnitude: 25,
            alphaValue: 0.8
        )

        XCTAssertEqual(point.intensity, 256)
        XCTAssertEqual(point.gradientMagnitude, 25)
        XCTAssertEqual(point.alphaValue, 0.8)
    }

    // MARK: - Codable Tests

    func testEncodingAndDecoding() throws {
        var tf = TransferFunction2D()
        tf.name = "Test 2D TF"
        tf.minimumIntensity = -500
        tf.maximumIntensity = 2000
        tf.minimumGradient = 10
        tf.maximumGradient = 200
        tf.shift = 100
        tf.colorSpace = .sRGB
        tf.intensityResolution = 512
        tf.gradientResolution = 128
        tf.colourPoints = [
            TransferFunction2D.ColorPoint2D(
                intensity: 0,
                gradientMagnitude: 50,
                colourValue: TransferFunction.RGBAColor(r: 1, g: 0, b: 0, a: 1)
            )
        ]
        tf.alphaPoints = [
            TransferFunction2D.AlphaPoint2D(intensity: 100, gradientMagnitude: 75, alphaValue: 0.5)
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(tf)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TransferFunction2D.self, from: data)

        XCTAssertEqual(decoded.name, "Test 2D TF")
        XCTAssertEqual(decoded.minimumIntensity, -500)
        XCTAssertEqual(decoded.maximumIntensity, 2000)
        XCTAssertEqual(decoded.minimumGradient, 10)
        XCTAssertEqual(decoded.maximumGradient, 200)
        XCTAssertEqual(decoded.shift, 100)
        XCTAssertEqual(decoded.colorSpace, .sRGB)
        XCTAssertEqual(decoded.intensityResolution, 512)
        XCTAssertEqual(decoded.gradientResolution, 128)
        XCTAssertEqual(decoded.colourPoints.count, 1)
        XCTAssertEqual(decoded.alphaPoints.count, 1)
    }

    func testDecodingWithMissingFields() throws {
        let json = """
        {
            "name": "Minimal"
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TransferFunction2D.self, from: data)

        XCTAssertEqual(decoded.name, "Minimal")
        XCTAssertTrue(decoded.colourPoints.isEmpty)
        XCTAssertTrue(decoded.alphaPoints.isEmpty)
        XCTAssertEqual(decoded.minimumIntensity, -1024)
        XCTAssertEqual(decoded.maximumIntensity, 3071)
        XCTAssertEqual(decoded.minimumGradient, 0)
        XCTAssertEqual(decoded.maximumGradient, 100)
    }

    // MARK: - Sanitized Color Points Tests

    func testSanitizedColourPointsFilterInfiniteValues() {
        var tf = TransferFunction2D()
        tf.colourPoints = [
            TransferFunction2D.ColorPoint2D(intensity: Float.infinity, gradientMagnitude: 50, colourValue: .init()),
            TransferFunction2D.ColorPoint2D(intensity: 100, gradientMagnitude: Float.nan, colourValue: .init()),
            TransferFunction2D.ColorPoint2D(intensity: 200, gradientMagnitude: 75, colourValue: .init())
        ]

        let sanitized = tf.sanitizedColourPoints()

        XCTAssertEqual(sanitized.count, 1) // One valid point remains after filtering
        XCTAssertTrue(sanitized.allSatisfy { $0.intensity.isFinite && $0.gradientMagnitude.isFinite })
    }

    func testSanitizedColourPointsClampsValues() {
        var tf = TransferFunction2D()
        tf.minimumIntensity = 0
        tf.maximumIntensity = 1000
        tf.minimumGradient = 0
        tf.maximumGradient = 100
        tf.colourPoints = [
            TransferFunction2D.ColorPoint2D(intensity: -500, gradientMagnitude: 50, colourValue: .init()),
            TransferFunction2D.ColorPoint2D(intensity: 2000, gradientMagnitude: 150, colourValue: .init())
        ]

        let sanitized = tf.sanitizedColourPoints()

        XCTAssertTrue(sanitized.allSatisfy { $0.intensity >= tf.minimumIntensity && $0.intensity <= tf.maximumIntensity })
        XCTAssertTrue(sanitized.allSatisfy { $0.gradientMagnitude >= tf.minimumGradient && $0.gradientMagnitude <= tf.maximumGradient })
    }

    func testSanitizedColourPointsSortsByIntensityThenGradient() {
        var tf = TransferFunction2D()
        tf.colourPoints = [
            TransferFunction2D.ColorPoint2D(intensity: 500, gradientMagnitude: 75, colourValue: .init()),
            TransferFunction2D.ColorPoint2D(intensity: 200, gradientMagnitude: 50, colourValue: .init()),
            TransferFunction2D.ColorPoint2D(intensity: 500, gradientMagnitude: 25, colourValue: .init())
        ]

        let sanitized = tf.sanitizedColourPoints()

        for index in 1..<sanitized.count {
            let prev = sanitized[index - 1]
            let curr = sanitized[index]
            XCTAssertTrue(
                (prev.intensity, prev.gradientMagnitude) < (curr.intensity, curr.gradientMagnitude),
                "Points must be sorted by (intensity, gradient)"
            )
        }
    }

    func testSanitizedColourPointsDeduplicates() {
        var tf = TransferFunction2D()
        tf.colourPoints = [
            TransferFunction2D.ColorPoint2D(
                intensity: 100,
                gradientMagnitude: 50,
                colourValue: TransferFunction.RGBAColor(r: 1, g: 0, b: 0, a: 1)
            ),
            TransferFunction2D.ColorPoint2D(
                intensity: 100,
                gradientMagnitude: 50,
                colourValue: TransferFunction.RGBAColor(r: 0, g: 1, b: 0, a: 1)
            )
        ]

        let sanitized = tf.sanitizedColourPoints()

        // Should keep the last one when duplicates exist
        let duplicateCount = sanitized.filter { $0.intensity == 100 && $0.gradientMagnitude == 50 }.count
        XCTAssertEqual(duplicateCount, 1, "Should deduplicate points at same (intensity, gradient)")
    }

    func testSanitizedColourPointsReturnsDefaultsWhenEmpty() {
        var tf = TransferFunction2D()
        tf.minimumIntensity = -1024
        tf.maximumIntensity = 3071
        tf.minimumGradient = 0
        tf.maximumGradient = 100
        tf.colourPoints = []

        let sanitized = tf.sanitizedColourPoints()

        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized[0].intensity, tf.minimumIntensity)
        XCTAssertEqual(sanitized[0].gradientMagnitude, tf.minimumGradient)
        XCTAssertEqual(sanitized[1].intensity, tf.maximumIntensity)
        XCTAssertEqual(sanitized[1].gradientMagnitude, tf.maximumGradient)
    }

    // MARK: - Sanitized Alpha Points Tests

    func testSanitizedAlphaPointsFilterInfiniteValues() {
        var tf = TransferFunction2D()
        tf.alphaPoints = [
            TransferFunction2D.AlphaPoint2D(intensity: Float.infinity, gradientMagnitude: 50, alphaValue: 0.5),
            TransferFunction2D.AlphaPoint2D(intensity: 100, gradientMagnitude: Float.nan, alphaValue: 0.5),
            TransferFunction2D.AlphaPoint2D(intensity: 200, gradientMagnitude: 75, alphaValue: Float.infinity),
            TransferFunction2D.AlphaPoint2D(intensity: 300, gradientMagnitude: 80, alphaValue: 0.8)
        ]

        let sanitized = tf.sanitizedAlphaPoints()

        XCTAssertEqual(sanitized.count, 1) // One valid point remains after filtering
        XCTAssertTrue(sanitized.allSatisfy {
            $0.intensity.isFinite && $0.gradientMagnitude.isFinite && $0.alphaValue.isFinite
        })
    }

    func testSanitizedAlphaPointsClampsValues() {
        var tf = TransferFunction2D()
        tf.minimumIntensity = 0
        tf.maximumIntensity = 1000
        tf.minimumGradient = 0
        tf.maximumGradient = 100
        tf.alphaPoints = [
            TransferFunction2D.AlphaPoint2D(intensity: -500, gradientMagnitude: 50, alphaValue: -0.5),
            TransferFunction2D.AlphaPoint2D(intensity: 2000, gradientMagnitude: 150, alphaValue: 1.5)
        ]

        let sanitized = tf.sanitizedAlphaPoints()

        XCTAssertTrue(sanitized.allSatisfy { $0.intensity >= tf.minimumIntensity && $0.intensity <= tf.maximumIntensity })
        XCTAssertTrue(sanitized.allSatisfy { $0.gradientMagnitude >= tf.minimumGradient && $0.gradientMagnitude <= tf.maximumGradient })
        XCTAssertTrue(sanitized.allSatisfy { $0.alphaValue >= 0 && $0.alphaValue <= 1 })
    }

    func testSanitizedAlphaPointsSortsByIntensityThenGradient() {
        var tf = TransferFunction2D()
        tf.alphaPoints = [
            TransferFunction2D.AlphaPoint2D(intensity: 500, gradientMagnitude: 75, alphaValue: 0.8),
            TransferFunction2D.AlphaPoint2D(intensity: 200, gradientMagnitude: 50, alphaValue: 0.5),
            TransferFunction2D.AlphaPoint2D(intensity: 500, gradientMagnitude: 25, alphaValue: 0.3)
        ]

        let sanitized = tf.sanitizedAlphaPoints()

        for index in 1..<sanitized.count {
            let prev = sanitized[index - 1]
            let curr = sanitized[index]
            XCTAssertTrue(
                (prev.intensity, prev.gradientMagnitude) < (curr.intensity, curr.gradientMagnitude),
                "Points must be sorted by (intensity, gradient)"
            )
        }
    }

    func testSanitizedAlphaPointsDeduplicates() {
        var tf = TransferFunction2D()
        tf.alphaPoints = [
            TransferFunction2D.AlphaPoint2D(intensity: 100, gradientMagnitude: 50, alphaValue: 0.3),
            TransferFunction2D.AlphaPoint2D(intensity: 100, gradientMagnitude: 50, alphaValue: 0.7)
        ]

        let sanitized = tf.sanitizedAlphaPoints()

        // Should keep the last one when duplicates exist
        let duplicateCount = sanitized.filter { $0.intensity == 100 && $0.gradientMagnitude == 50 }.count
        XCTAssertEqual(duplicateCount, 1, "Should deduplicate points at same (intensity, gradient)")
    }

    func testSanitizedAlphaPointsReturnsDefaultsWhenEmpty() {
        var tf = TransferFunction2D()
        tf.minimumIntensity = -1024
        tf.maximumIntensity = 3071
        tf.minimumGradient = 0
        tf.maximumGradient = 100
        tf.alphaPoints = []

        let sanitized = tf.sanitizedAlphaPoints()

        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized[0].intensity, tf.minimumIntensity)
        XCTAssertEqual(sanitized[0].gradientMagnitude, tf.minimumGradient)
        XCTAssertEqual(sanitized[0].alphaValue, 0)
        XCTAssertEqual(sanitized[1].intensity, tf.maximumIntensity)
        XCTAssertEqual(sanitized[1].gradientMagnitude, tf.maximumGradient)
        XCTAssertEqual(sanitized[1].alphaValue, 1)
    }

    func testSanitizedAlphaPointsRespectsCustomDefaultRange() {
        var tf = TransferFunction2D()
        tf.alphaPoints = []

        let sanitized = tf.sanitizedAlphaPoints(defaultRange: (0.2, 0.8))

        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized[0].alphaValue, 0.2)
        XCTAssertEqual(sanitized[1].alphaValue, 0.8)
    }

    // MARK: - Texture Generation Tests

    @MainActor
    func testMakeTextureCreates2DTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this device")
        }

        var tf = TransferFunction2D()
        tf.name = "Test Texture"
        tf.intensityResolution = 128
        tf.gradientResolution = 64
        tf.colourPoints = [
            TransferFunction2D.ColorPoint2D(
                intensity: -1024,
                gradientMagnitude: 0,
                colourValue: TransferFunction.RGBAColor(r: 0, g: 0, b: 0, a: 1)
            ),
            TransferFunction2D.ColorPoint2D(
                intensity: 3071,
                gradientMagnitude: 100,
                colourValue: TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1)
            )
        ]
        tf.alphaPoints = [
            TransferFunction2D.AlphaPoint2D(intensity: -1024, gradientMagnitude: 0, alphaValue: 0),
            TransferFunction2D.AlphaPoint2D(intensity: 3071, gradientMagnitude: 100, alphaValue: 1)
        ]

        let texture = tf.makeTexture(device: device)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 128)
        XCTAssertEqual(texture?.height, 64)
        XCTAssertEqual(texture?.pixelFormat, .rgba32Float)
        XCTAssertEqual(texture?.textureType, .type2D)
        XCTAssertTrue(texture?.label?.contains("TF2D") ?? false)
    }

    @MainActor
    func testMakeTextureWithDefaultResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this device")
        }

        let tf = TransferFunction2D()
        let texture = tf.makeTexture(device: device)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 256)
        XCTAssertEqual(texture?.height, 256)
    }

    @MainActor
    func testMakeTextureWithCustomResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available on this device")
        }

        var tf = TransferFunction2D()
        tf.intensityResolution = 512
        tf.gradientResolution = 128

        let texture = tf.makeTexture(device: device)

        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 512)
        XCTAssertEqual(texture?.height, 128)
    }

    // MARK: - Load from URL Tests

    func testLoadFromValidJSONFile() throws {
        let json = """
        {
            "name": "File Test",
            "minIntensity": -500,
            "maxIntensity": 2000,
            "minGradient": 10,
            "maxGradient": 150,
            "intensityResolution": 512,
            "gradientResolution": 256,
            "colourPoints": [
                {
                    "intensity": 0,
                    "gradientMagnitude": 50,
                    "colourValue": {"r": 1, "g": 0, "b": 0, "a": 1}
                }
            ],
            "alphaPoints": [
                {
                    "intensity": 100,
                    "gradientMagnitude": 75,
                    "alphaValue": 0.5
                }
            ]
        }
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tf2d")

        try json.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loaded = TransferFunction2D.load(from: tempURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "File Test")
        XCTAssertEqual(loaded?.minimumIntensity, -500)
        XCTAssertEqual(loaded?.maximumIntensity, 2000)
        XCTAssertEqual(loaded?.minimumGradient, 10)
        XCTAssertEqual(loaded?.maximumGradient, 150)
        XCTAssertEqual(loaded?.intensityResolution, 512)
        XCTAssertEqual(loaded?.gradientResolution, 256)
        XCTAssertEqual(loaded?.colourPoints.count, 1)
        XCTAssertEqual(loaded?.alphaPoints.count, 1)
    }

    func testLoadFromInvalidFileReturnsNil() {
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tf2d")

        let loaded = TransferFunction2D.load(from: invalidURL)

        XCTAssertNil(loaded, "Loading from non-existent file should return nil")
    }

    func testLoadFromMalformedJSONReturnsNil() throws {
        let malformedJSON = """
        {
            "name": "Malformed",
            "minIntensity": "not a number"
        }
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tf2d")

        try malformedJSON.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loaded = TransferFunction2D.load(from: tempURL)

        XCTAssertNil(loaded, "Loading malformed JSON should return nil")
    }
}
