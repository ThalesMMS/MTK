//
//  ToneCurveEditor.swift
//  MTK
//
//  Tone curve editor for volume rendering.
//

import SwiftUI
import MTKCore
import simd

public enum ToneCurveEditorTransferFunctionAdapter {
    public static func normalizedControlPoints(for transferFunction: TransferFunction) -> [SIMD2<Float>] {
        let span = max(transferFunction.maximumValue - transferFunction.minimumValue, Float.leastNonzeroMagnitude)
        return transferFunction
            .sanitizedAlphaPoints()
            .map { point in
                SIMD2<Float>(
                    VolumetricMath.clampFloat((point.dataValue - transferFunction.minimumValue) / span,
                                              lower: 0,
                                              upper: 1),
                    VolumetricMath.clampFloat(point.alphaValue, lower: 0, upper: 1)
                )
            }
    }

    public static func update(_ transferFunction: inout TransferFunction,
                              normalizedControlPoints: [SIMD2<Float>]) {
        let span = max(transferFunction.maximumValue - transferFunction.minimumValue, Float.leastNonzeroMagnitude)
        let sorted = normalizedControlPoints
            .map { point in
                SIMD2<Float>(
                    VolumetricMath.clampFloat(point.x, lower: 0, upper: 1),
                    VolumetricMath.clampFloat(point.y, lower: 0, upper: 1)
                )
            }
            .sorted { $0.x < $1.x }

        var deduplicated: [SIMD2<Float>] = []
        for point in sorted {
            if let last = deduplicated.last, last.x == point.x {
                deduplicated[deduplicated.count - 1] = point
            } else {
                deduplicated.append(point)
            }
        }

        guard !deduplicated.isEmpty else {
            transferFunction.alphaPoints = [
                .init(dataValue: transferFunction.minimumValue, alphaValue: 0),
                .init(dataValue: transferFunction.maximumValue, alphaValue: 1)
            ]
            transferFunction.version = TransferFunction.currentVersion
            return
        }

        if deduplicated[0].x > 0 {
            deduplicated.insert(SIMD2<Float>(0, deduplicated[0].y), at: 0)
        } else {
            deduplicated[0].x = 0
        }

        if deduplicated[deduplicated.count - 1].x < 1 {
            deduplicated.append(SIMD2<Float>(1, deduplicated[deduplicated.count - 1].y))
        } else {
            deduplicated[deduplicated.count - 1].x = 1
        }

        transferFunction.alphaPoints = deduplicated.map { point in
            TransferFunction.AlphaPoint(
                dataValue: transferFunction.minimumValue + span * point.x,
                alphaValue: point.y
            )
        }
        transferFunction.version = TransferFunction.currentVersion
    }
}

public struct ToneCurveEditor: View {
    private let transferFunctionBinding: Binding<TransferFunction>?
    private let onTransferFunctionChange: ((TransferFunction) -> Void)?

    @Binding private var controlPoints: [SIMD2<Float>]
    @Binding private var gain: Float
    private let channel: Int
    private let onChange: ([SIMD2<Float>], Float) -> Void

    @State private var selectedPointIndex: Int?

    public init(transferFunction: Binding<TransferFunction>,
                onChange: @escaping (TransferFunction) -> Void = { _ in }) {
        self.transferFunctionBinding = transferFunction
        self.onTransferFunctionChange = onChange
        self._controlPoints = .constant([])
        self._gain = .constant(1)
        self.channel = 0
        self.onChange = { _, _ in }
    }

    public init(controlPoints: Binding<[SIMD2<Float>]>,
                gain: Binding<Float>,
                channel: Int,
                onChange: @escaping ([SIMD2<Float>], Float) -> Void) {
        self.transferFunctionBinding = nil
        self.onTransferFunctionChange = nil
        self._controlPoints = controlPoints
        self._gain = gain
        self.channel = channel
        self.onChange = onChange
    }

    public var body: some View {
        if let transferFunctionBinding {
            transferFunctionEditor(transferFunctionBinding)
        } else {
            legacyEditor
        }
    }

    private func transferFunctionEditor(_ binding: Binding<TransferFunction>) -> some View {
        let points = ToneCurveEditorTransferFunctionAdapter.normalizedControlPoints(for: binding.wrappedValue)

        return VStack(alignment: .leading, spacing: 16) {
            Text(binding.wrappedValue.metadata?.displayName ?? binding.wrappedValue.name)
                .font(.headline)

            curveCanvas(points: points) { index, newPoint in
                guard index > 0 && index < points.count - 1 else { return }
                var updatedPoints = points
                updatedPoints[index] = newPoint
                var transferFunction = binding.wrappedValue
                ToneCurveEditorTransferFunctionAdapter.update(&transferFunction,
                                                              normalizedControlPoints: updatedPoints)
                binding.wrappedValue = transferFunction
                onTransferFunctionChange?(transferFunction)
            }

            HStack {
                Button("Linear") {
                    applyNormalizedPoints([
                        SIMD2<Float>(0, 0),
                        SIMD2<Float>(1, 1)
                    ], to: binding)
                }

                Button("S-Curve") {
                    applyNormalizedPoints([
                        SIMD2<Float>(0, 0),
                        SIMD2<Float>(0.25, 0.08),
                        SIMD2<Float>(0.5, 0.45),
                        SIMD2<Float>(0.75, 0.9),
                        SIMD2<Float>(1, 1)
                    ], to: binding)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var legacyEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tone Curve - Channel \(channel)")
                .font(.headline)

            curveCanvas(points: controlPoints) { index, newPoint in
                var newPoints = controlPoints
                if index > 0 && index < controlPoints.count - 1 {
                    newPoints[index] = newPoint
                    controlPoints = newPoints
                    onChange(newPoints, gain)
                }
            }

            VStack(alignment: .leading) {
                Text("Gain: \(String(format: "%.2f", gain))")
                Slider(value: $gain, in: 0.1...3.0, step: 0.1) { _ in
                    onChange(controlPoints, gain)
                }
            }

            HStack {
                Button("Reset") {
                    controlPoints = [
                        SIMD2<Float>(0, 0),
                        SIMD2<Float>(0.25, 0.25),
                        SIMD2<Float>(0.5, 0.5),
                        SIMD2<Float>(0.75, 0.75),
                        SIMD2<Float>(1, 1)
                    ]
                    gain = 1.0
                    onChange(controlPoints, gain)
                }

                Button("Linear") {
                    controlPoints = [
                        SIMD2<Float>(0, 0),
                        SIMD2<Float>(1, 1)
                    ]
                    onChange(controlPoints, gain)
                }

                Button("S-Curve") {
                    controlPoints = [
                        SIMD2<Float>(0, 0),
                        SIMD2<Float>(0.25, 0.1),
                        SIMD2<Float>(0.5, 0.5),
                        SIMD2<Float>(0.75, 0.9),
                        SIMD2<Float>(1, 1)
                    ]
                    onChange(controlPoints, gain)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func curveCanvas(points: [SIMD2<Float>],
                             updatePoint: @escaping (Int, SIMD2<Float>) -> Void) -> some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    for i in stride(from: 0.0, through: 1.0, by: 0.25) {
                        let x = CGFloat(i) * width
                        let y = CGFloat(i) * height
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                }
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                }
                .stroke(Color.blue.opacity(0.5), lineWidth: 1)

                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let sortedPoints = points.sorted { $0.x < $1.x }
                    for (index, point) in sortedPoints.enumerated() {
                        let x = CGFloat(point.x) * width
                        let y = height - (CGFloat(point.y) * height)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.red, lineWidth: 2)

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(selectedPointIndex == index ? Color.blue : Color.red)
                        .frame(width: 12, height: 12)
                        .position(
                            x: CGFloat(point.x) * geometry.size.width,
                            y: geometry.size.height - (CGFloat(point.y) * geometry.size.height)
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    selectedPointIndex = index
                                    updatePoint(
                                        index,
                                        SIMD2<Float>(
                                            VolumetricMath.clampFloat(Float(value.location.x / geometry.size.width),
                                                                      lower: 0,
                                                                      upper: 1),
                                            VolumetricMath.clampFloat(1.0 - Float(value.location.y / geometry.size.height),
                                                                      lower: 0,
                                                                      upper: 1)
                                        )
                                    )
                                }
                                .onEnded { _ in
                                    selectedPointIndex = nil
                                }
                        )
                }
            }
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .frame(height: 200)
    }

    private func applyNormalizedPoints(_ points: [SIMD2<Float>],
                                       to binding: Binding<TransferFunction>) {
        var transferFunction = binding.wrappedValue
        ToneCurveEditorTransferFunctionAdapter.update(&transferFunction,
                                                      normalizedControlPoints: points)
        binding.wrappedValue = transferFunction
        onTransferFunctionChange?(transferFunction)
    }
}

public struct ToneCurveEditorView: View {
    @State private var transferFunction: TransferFunction

    public init() {
        var transferFunction = TransferFunction()
        transferFunction.name = "Custom Transfer Function"
        transferFunction.minimumValue = -1024
        transferFunction.maximumValue = 3071
        transferFunction.alphaPoints = [
            .init(dataValue: -1024, alphaValue: 0),
            .init(dataValue: 3071, alphaValue: 1)
        ]
        self._transferFunction = State(initialValue: transferFunction)
    }

    public var body: some View {
        ToneCurveEditor(transferFunction: $transferFunction)
    }
}
