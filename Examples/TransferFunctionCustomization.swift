//
//  TransferFunctionCustomization.swift
//  MTK Examples
//
//  Example demonstrating custom tone curves and window/level presets
//  Thales Matheus Mendonça Santos — November 2025
//
//  NOTE: This is example/documentation code showing transfer function customization.
//  For complete UI implementation, see MTK-Demo's SceneViewController.
//

import SwiftUI
import MTKCore
import MTKUI
import Metal

// MARK: - Custom Tone Curve Example

/// Example showing manual tone curve editing with control points
///
/// This example demonstrates:
/// 1. Creating an AdvancedToneCurveModel
/// 2. Adding/editing control points
/// 3. Sampling the curve for rendering
/// 4. Applying the curve to volume visualization
struct CustomToneCurveExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @StateObject private var toneCurveModel = AdvancedToneCurveModel()
    @State private var sampledValues: [Float] = []

    var body: some View {
        VStack {
            VolumetricDisplayContainer(controller: coordinator.controller) {
                OrientationOverlayView()
            }

            // Display current control points
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Control Points")
                        .font(.headline)

                    ForEach(Array(toneCurveModel.currentControlPoints().enumerated()), id: \.offset) { index, point in
                        HStack {
                            Text("Point \(index)")
                            Text("X: \(String(format: "%.1f", point.x))")
                            Text("Y: \(String(format: "%.2f", point.y))")
                        }
                        .font(.caption)
                    }
                }
                .padding()
            }
            .frame(height: 150)
        }
        .task {
            await setupCustomToneCurve()
        }
    }

    private func setupCustomToneCurve() async {
        // Step 1: Define custom control points for a steep contrast curve
        // This creates a high-contrast S-curve emphasizing mid-range intensities
        let customPoints: [AdvancedToneCurvePoint] = [
            .init(x: 0, y: 0),        // Start at zero
            .init(x: 50, y: 0.1),     // Gradual ramp-up
            .init(x: 100, y: 0.4),    // Mid-low transition
            .init(x: 128, y: 0.6),    // Midpoint with steep slope
            .init(x: 180, y: 0.9),    // Mid-high transition
            .init(x: 255, y: 1.0)     // Full opacity
        ]

        // Step 2: Set control points (automatically sanitized)
        toneCurveModel.setControlPoints(customPoints)

        // Step 3: Choose interpolation mode
        // .cubicSpline = smooth curves (default)
        // .linear = straight lines between points
        toneCurveModel.interpolationMode = .cubicSpline

        // Step 4: Generate sampled values for the curve
        // Default scale is 10, producing 2551 samples (255 × 10 + 1)
        sampledValues = toneCurveModel.sampledValues()

        print("Generated \(sampledValues.count) tone curve samples")

        // Step 5: Apply to volume rendering
        // Note: In a complete implementation, sampledValues would be uploaded
        // to a Metal texture and used in the volume rendering shader
    }
}

// MARK: - Auto-Window Preset Example

/// Example showing automatic windowing based on histogram analysis
///
/// This example demonstrates:
/// 1. Setting histogram data for auto-windowing
/// 2. Applying predefined auto-window presets
/// 3. Understanding different windowing algorithms
struct AutoWindowPresetExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @StateObject private var toneCurveModel = AdvancedToneCurveModel()
    @State private var currentPreset: ToneCurveAutoWindowPreset = .abdomen

    var body: some View {
        VStack {
            VolumetricDisplayContainer(controller: coordinator.controller) {
                OrientationOverlayView()
            }

            // Preset selector
            Picker("Auto-Window Preset", selection: $currentPreset) {
                Text("Abdomen").tag(ToneCurveAutoWindowPreset.abdomen)
                Text("Lung").tag(ToneCurveAutoWindowPreset.lung)
                Text("Bone").tag(ToneCurveAutoWindowPreset.bone)
                Text("Otsu Threshold").tag(ToneCurveAutoWindowPreset.otsu)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: currentPreset) { _, newPreset in
                applyAutoWindowPreset(newPreset)
            }

            // Preset information
            VStack(alignment: .leading, spacing: 4) {
                Text("Preset: \(currentPreset.title)")
                    .font(.headline)

                if let lower = currentPreset.lowerPercentile,
                   let upper = currentPreset.upperPercentile {
                    Text("Percentiles: \(String(format: "%.1f%%", lower * 100)) - \(String(format: "%.1f%%", upper * 100))")
                } else {
                    Text("Algorithm: Otsu threshold")
                }

                Text("Smoothing radius: \(currentPreset.smoothingRadius) bins")
            }
            .font(.caption)
            .padding()
        }
        .task {
            await setupAutoWindowing()
        }
    }

    private func setupAutoWindowing() async {
        // Step 1: Obtain histogram from volume dataset
        // In a real implementation, this would come from VolumeHistogramCalculator
        // or MetalVolumeRenderingAdapter.getHistogram()
        let sampleHistogram = generateSampleHistogram()

        // Step 2: Set histogram data (must be 256 or 512 bins)
        toneCurveModel.setHistogram(sampleHistogram)

        // Step 3: Apply initial preset
        applyAutoWindowPreset(.abdomen)
    }

    private func applyAutoWindowPreset(_ preset: ToneCurveAutoWindowPreset) {
        // Apply auto-window algorithm based on histogram
        toneCurveModel.applyAutoWindow(preset)

        // The tone curve control points are now automatically adjusted
        // based on the histogram distribution and preset parameters

        print("Applied auto-window preset: \(preset.title)")
        print("Generated \(toneCurveModel.currentControlPoints().count) control points")
    }

    private func generateSampleHistogram() -> [UInt32] {
        // Generate a sample CT histogram (256 bins)
        // In reality, this comes from VolumeHistogramCalculator
        var histogram = [UInt32](repeating: 0, count: 256)

        // Simulate bimodal distribution (air + soft tissue)
        for i in 0..<256 {
            let normalized = Float(i) / 255.0
            let airPeak = exp(-pow((normalized - 0.1) * 10, 2))
            let tissuePeak = exp(-pow((normalized - 0.6) * 5, 2))
            histogram[i] = UInt32((airPeak + tissuePeak * 2) * 1000)
        }

        return histogram
    }
}

// MARK: - Window/Level Preset Example

/// Example showing standard window/level presets for medical imaging
///
/// This example demonstrates:
/// 1. Using WindowLevelPresetLibrary for standard presets
/// 2. Converting window/level to min/max bounds
/// 3. Applying presets to volume visualization
struct WindowLevelPresetExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var selectedPreset: WindowLevelPreset = WindowLevelPresetLibrary.ct[0]
    @State private var minHU: Float = -160
    @State private var maxHU: Float = 240

    var body: some View {
        VStack {
            VolumetricDisplayContainer(controller: coordinator.controller) {
                OrientationOverlayView()
            }

            // CT Preset selector
            List {
                Section("OHIF Presets") {
                    ForEach(WindowLevelPresetLibrary.ct.filter { $0.source == .ohif }) { preset in
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                        .font(.headline)
                                    Text(preset.windowLevelSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPreset.id == preset.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Weasis Presets") {
                    ForEach(WindowLevelPresetLibrary.ct.filter { $0.source == .weasis }) { preset in
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                        .font(.headline)
                                    Text(preset.windowLevelSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPreset.id == preset.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Current Values") {
                    Text("Window: \(Int(selectedPreset.window))")
                    Text("Level: \(Int(selectedPreset.level))")
                    Text("Min HU: \(Int(minHU))")
                    Text("Max HU: \(Int(maxHU))")
                }
            }
        }
    }

    private func applyPreset(_ preset: WindowLevelPreset) {
        // Step 1: Select the preset
        selectedPreset = preset

        // Step 2: Convert window/level to min/max bounds
        minHU = preset.minValue
        maxHU = preset.maxValue

        // Step 3: Apply to coordinator
        coordinator.applyHuWindow(min: Int32(minHU), max: Int32(maxHU))

        print("Applied preset: \(preset.fullDisplayName)")
        print("Window: \(preset.window), Level: \(preset.level)")
        print("Min: \(minHU) HU, Max: \(maxHU) HU")
    }
}

// MARK: - Custom Transfer Function from File

/// Example showing how to load and customize transfer functions from .tf files
///
/// This example demonstrates:
/// 1. Loading TransferFunction from JSON .tf files
/// 2. Modifying color and alpha control points
/// 3. Generating Metal textures for rendering
struct CustomTransferFunctionExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @State private var transferFunction: TransferFunction?
    @State private var metalDevice: MTLDevice?

    var body: some View {
        VStack {
            VolumetricDisplayContainer(controller: coordinator.controller) {
                OrientationOverlayView()
            }

            if let tf = transferFunction {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transfer Function: \(tf.name)")
                        .font(.headline)
                    Text("Range: \(Int(tf.minimumValue))...\(Int(tf.maximumValue))")
                    Text("Color Space: \(tf.colorSpace.rawValue)")
                    Text("Color Points: \(tf.colourPoints.count)")
                    Text("Alpha Points: \(tf.alphaPoints.count)")
                }
                .padding()
            }
        }
        .task {
            setupTransferFunction()
        }
    }

    private func setupTransferFunction() {
        // Step 1: Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal device not available")
            return
        }
        metalDevice = device

        // Step 2: Create a custom transfer function programmatically
        // (In a real app, load from .tf file using TransferFunction.load(from: url))
        var tf = TransferFunction()
        tf.name = "Custom CT Bone"
        tf.minimumValue = -1024
        tf.maximumValue = 3071
        tf.colorSpace = .linear

        // Step 3: Define color control points
        tf.colourPoints = [
            .init(dataValue: -1024, colourValue: .init(r: 0.2, g: 0.15, b: 0.1, a: 1.0)),
            .init(dataValue: 200, colourValue: .init(r: 0.8, g: 0.6, b: 0.4, a: 1.0)),
            .init(dataValue: 1000, colourValue: .init(r: 1.0, g: 0.95, b: 0.85, a: 1.0)),
            .init(dataValue: 3071, colourValue: .init(r: 1.0, g: 1.0, b: 1.0, a: 1.0))
        ]

        // Step 4: Define alpha (opacity) control points
        tf.alphaPoints = [
            .init(dataValue: -1024, alphaValue: 0.0),
            .init(dataValue: 200, alphaValue: 0.0),    // Transparent below bone threshold
            .init(dataValue: 400, alphaValue: 0.3),    // Gradual ramp-up
            .init(dataValue: 800, alphaValue: 0.7),    // Dense bone
            .init(dataValue: 1500, alphaValue: 0.95),  // Very dense bone
            .init(dataValue: 3071, alphaValue: 1.0)
        ]

        transferFunction = tf

        // Step 5: Generate Metal texture for rendering
        generateTransferFunctionTexture(tf, device: device)
    }

    @MainActor
    private func generateTransferFunctionTexture(_ tf: TransferFunction, device: MTLDevice) {
        // Generate 1D RGBA texture from transfer function
        guard let texture = tf.makeTexture(device: device) else {
            print("Failed to generate transfer function texture")
            return
        }

        print("Generated transfer function texture:")
        print("  Width: \(texture.width)")
        print("  Pixel Format: \(texture.pixelFormat)")
        print("  Name: \(tf.name)")

        // In a complete implementation, bind this texture to the volume rendering shader
        // and use it to map volume intensities to RGBA colors during ray marching
    }
}

// MARK: - Advanced: Combining Presets with Custom Adjustments

/// Example showing how to combine built-in presets with custom adjustments
///
/// This example demonstrates:
/// 1. Loading built-in transfer function presets
/// 2. Applying tone curve auto-windowing on top
/// 3. Fine-tuning with manual window/level adjustments
struct CombinedCustomizationExample: View {

    @StateObject private var coordinator = VolumetricSceneCoordinator.shared
    @StateObject private var toneCurveModel = AdvancedToneCurveModel()
    @State private var currentBuiltinPreset: VolumeRenderingBuiltinPreset = .softTissue
    @State private var windowMin: Int32 = -160
    @State private var windowMax: Int32 = 240

    var body: some View {
        VStack {
            VolumetricDisplayContainer(controller: coordinator.controller) {
                OrientationOverlayView()
                CrosshairOverlayView()
            }

            Form {
                Section("1. Built-in Transfer Function") {
                    Picker("Preset", selection: $currentBuiltinPreset) {
                        Text("Soft Tissue").tag(VolumeRenderingBuiltinPreset.softTissue)
                        Text("Bone").tag(VolumeRenderingBuiltinPreset.bone)
                        Text("Lung").tag(VolumeRenderingBuiltinPreset.lung)
                        Text("Angio").tag(VolumeRenderingBuiltinPreset.angio)
                    }
                    .onChange(of: currentBuiltinPreset) { _, newPreset in
                        Task {
                            await coordinator.controller.setPreset(newPreset)
                        }
                    }
                }

                Section("2. Auto-Window Adjustment") {
                    Button("Apply Abdomen Window") {
                        toneCurveModel.applyAutoWindow(.abdomen)
                        updateWindowFromToneCurve()
                    }

                    Button("Apply Lung Window") {
                        toneCurveModel.applyAutoWindow(.lung)
                        updateWindowFromToneCurve()
                    }

                    Button("Apply Bone Window") {
                        toneCurveModel.applyAutoWindow(.bone)
                        updateWindowFromToneCurve()
                    }
                }

                Section("3. Manual Fine-Tuning") {
                    HStack {
                        Text("Min HU:")
                        Slider(value: Binding(
                            get: { Float(windowMin) },
                            set: { windowMin = Int32($0) }
                        ), in: -1024...3071, step: 10)
                        Text("\(windowMin)")
                    }

                    HStack {
                        Text("Max HU:")
                        Slider(value: Binding(
                            get: { Float(windowMax) },
                            set: { windowMax = Int32($0) }
                        ), in: -1024...3071, step: 10)
                        Text("\(windowMax)")
                    }

                    Button("Apply Window") {
                        coordinator.applyHuWindow(min: windowMin, max: windowMax)
                    }
                }
            }
        }
        .task {
            await setupCombinedCustomization()
        }
    }

    private func setupCombinedCustomization() async {
        // Step 1: Apply built-in transfer function preset
        await coordinator.controller.setPreset(currentBuiltinPreset)

        // Step 2: Set histogram for auto-windowing (if available)
        // In a real implementation, get histogram from renderer
        // let histogram = try? await coordinator.controller.getHistogram()
        // toneCurveModel.setHistogram(histogram ?? [])

        // Step 3: Set initial window/level
        coordinator.applyHuWindow(min: windowMin, max: windowMax)
    }

    private func updateWindowFromToneCurve() {
        // Extract window bounds from tone curve control points
        let points = toneCurveModel.currentControlPoints()
        if points.count >= 2 {
            // Use first and last significant opacity points
            let significantPoints = points.filter { $0.y > 0.1 }
            if let first = significantPoints.first,
               let last = significantPoints.last {
                // Convert from 0-255 normalized range to HU range (-1024...3071)
                let huRange: Float = 3071 - (-1024)
                windowMin = Int32(first.x / 255.0 * huRange - 1024)
                windowMax = Int32(last.x / 255.0 * huRange - 1024)

                coordinator.applyHuWindow(min: windowMin, max: windowMax)
            }
        }
    }
}

// MARK: - Usage Notes

/*
 ## Overview

 Transfer function customization is essential for optimal medical image visualization.
 MTK provides multiple approaches for customizing how volume intensities map to colors and opacity:

 1. **Transfer Functions** (TransferFunction)
    - Color and alpha control points with linear interpolation
    - Load from .tf JSON files or create programmatically
    - Generate Metal textures for GPU-based rendering

 2. **Tone Curves** (AdvancedToneCurveModel)
    - Cubic spline or linear interpolation
    - Manual control point editing
    - Auto-windowing based on histogram analysis
    - Presets: abdomen, lung, bone, Otsu threshold

 3. **Window/Level Presets** (WindowLevelPresetLibrary)
    - Standard medical imaging window/level values
    - OHIF and Weasis preset collections
    - CT and PET modality support

 ## Quick Start

 ### 1. Using Built-in Transfer Function Presets

 ```swift
 // Load a built-in preset
 if let tf = VolumeTransferFunctionLibrary.transferFunction(for: .ctBone) {
     print("Loaded: \(tf.name)")
     print("Range: \(tf.minimumValue)...\(tf.maximumValue)")

     // Generate Metal texture
     if let texture = tf.makeTexture(device: metalDevice) {
         // Apply to volume renderer
     }
 }
 ```

 ### 2. Creating Custom Tone Curves

 ```swift
 let toneCurve = AdvancedToneCurveModel()

 // Define control points
 let points = [
     AdvancedToneCurvePoint(x: 0, y: 0),
     AdvancedToneCurvePoint(x: 100, y: 0.3),
     AdvancedToneCurvePoint(x: 200, y: 0.8),
     AdvancedToneCurvePoint(x: 255, y: 1.0)
 ]
 toneCurve.setControlPoints(points)

 // Generate samples for rendering
 let samples = toneCurve.sampledValues()  // 2551 samples
 ```

 ### 3. Auto-Windowing with Histogram

 ```swift
 let toneCurve = AdvancedToneCurveModel()

 // Set histogram data (256 or 512 bins)
 toneCurve.setHistogram(histogramValues)

 // Apply preset
 toneCurve.applyAutoWindow(.abdomen)
 toneCurve.applyAutoWindow(.lung)
 toneCurve.applyAutoWindow(.bone)
 toneCurve.applyAutoWindow(.otsu)  // Otsu thresholding
 ```

 ### 4. Using Window/Level Presets

 ```swift
 // Get all CT presets
 let ctPresets = WindowLevelPresetLibrary.ct

 // Apply a specific preset
 let softTissue = WindowLevelPresetLibrary.ct.first { $0.id == "ohif.ct-soft-tissue" }!
 let (minHU, maxHU) = (softTissue.minValue, softTissue.maxValue)

 coordinator.applyHuWindow(min: Int32(minHU), max: Int32(maxHU))
 ```

 ### 5. Loading from .tf Files

 ```swift
 let url = Bundle.main.url(forResource: "ct_bone", withExtension: "tf")!

 if let tf = TransferFunction.load(from: url) {
     print("Loaded: \(tf.name)")
     print("Color points: \(tf.colourPoints.count)")
     print("Alpha points: \(tf.alphaPoints.count)")

     // Generate texture for rendering
     let texture = tf.makeTexture(device: metalDevice)
 }
 ```

 ## Transfer Function File Format

 Transfer functions are stored as JSON `.tf` files:

 ```json
 {
   "version": 1,
   "name": "CT Bone",
   "min": -1024,
   "max": 3071,
   "colorSpace": "linear",
   "colourPoints": [
     {"dataValue": -1024, "colourValue": {"r": 0.2, "g": 0.15, "b": 0.1, "a": 1}},
     {"dataValue": 3071, "colourValue": {"r": 1, "g": 0.95, "b": 0.9, "a": 1}}
   ],
   "alphaPoints": [
     {"dataValue": -1024, "alphaValue": 0},
     {"dataValue": 200, "alphaValue": 0},
     {"dataValue": 1000, "alphaValue": 0.8},
     {"dataValue": 3071, "alphaValue": 1}
   ]
 }
 ```

 ## Tone Curve Auto-Window Presets

 - **Abdomen**: Percentiles 10%-90%, smoothing radius 3
   - Optimized for abdominal CT with soft tissue and organ visualization

 - **Lung**: Percentiles 0.5%-60%, smoothing radius 4
   - Emphasizes air-filled regions and pulmonary vessels

 - **Bone**: Percentiles 40%-99.5%, smoothing radius 2
   - High-density bone structures, preserves fine detail

 - **Otsu**: Automatic thresholding via between-class variance
   - Effective for bimodal histograms (contrast-enhanced imaging)

 ## Window/Level Math

 ```swift
 // Convert window/level to min/max
 let (minHU, maxHU) = WindowLevelMath.bounds(forWidth: 400, level: 40)
 // minHU = -159.5, maxHU = 239.5

 // Convert min/max to window/level
 let (width, level) = WindowLevelMath.widthLevel(forMin: -160, max: 240)
 // width = 401, level = 40
 ```

 ## Next Steps

 - See `BasicVolumeRendering.swift` for basic volume setup
 - See `MPRViewer.swift` for multi-plane reconstruction
 - See MTK-Demo for complete UI implementation with interactive tone curve editor
 - Consult MTK documentation for advanced transfer function techniques
 */
