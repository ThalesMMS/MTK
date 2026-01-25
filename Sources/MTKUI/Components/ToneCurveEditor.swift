//
//  ToneCurveEditor.swift
//  MTK
//
//  Tone curve editor for volume rendering
//  Thales Matheus Mendonça Santos — November 2025
//

import SwiftUI
import simd

public struct ToneCurveEditor: View {
    
    @Binding private var controlPoints: [SIMD2<Float>]
    @Binding private var gain: Float
    private let channel: Int
    private let onChange: ([SIMD2<Float>], Float) -> Void
    
    @State private var selectedPointIndex: Int?
    @State private var isDragging = false
    
    public init(controlPoints: Binding<[SIMD2<Float>]>, 
                gain: Binding<Float>, 
                channel: Int,
                onChange: @escaping ([SIMD2<Float>], Float) -> Void) {
        self._controlPoints = controlPoints
        self._gain = gain
        self.channel = channel
        self.onChange = onChange
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tone Curve - Channel \(channel)")
                .font(.headline)
            
            GeometryReader { geometry in
                ZStack {
                    // Grid background
                    Path { path in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        
                        // Draw grid lines
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
                    
                    // Diagonal line
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                    }
                    .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                    
                    // Tone curve
                    Path { path in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        
                        guard !controlPoints.isEmpty else { return }
                        
                        let sortedPoints = controlPoints.sorted { $0.x < $1.x }
                        
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
                    
                    // Control points
                    ForEach(Array(controlPoints.enumerated()), id: \.offset) { index, point in
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
                                        let newX = Float(value.location.x / geometry.size.width)
                                        let newY = 1.0 - Float(value.location.y / geometry.size.height)
                                        
                                        var newPoints = controlPoints
                                        if index > 0 && index < controlPoints.count - 1 {
                                            newPoints[index] = SIMD2<Float>(
                                                max(0, min(1, newX)),
                                                max(0, min(1, newY))
                                            )
                                            controlPoints = newPoints
                                            onChange(newPoints, gain)
                                        }
                                    }
                            )
                    }
                }
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            .frame(height: 200)
            
            // Gain slider
            VStack(alignment: .leading) {
                Text("Gain: \(String(format: "%.2f", gain))")
                Slider(value: $gain, in: 0.1...3.0, step: 0.1) { _ in
                    onChange(controlPoints, gain)
                }
            }
            
            // Preset buttons
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
}

public struct ToneCurveEditorView: View {
    
    @State private var controlPoints: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.25, 0.25),
        SIMD2<Float>(0.5, 0.5),
        SIMD2<Float>(0.75, 0.75),
        SIMD2<Float>(1, 1)
    ]
    
    @State private var gain: Float = 1.0
    
    public init() {}
    
    public var body: some View {
        VStack {
            ToneCurveEditor(
                controlPoints: $controlPoints,
                gain: $gain,
                channel: 0
            ) { points, gain in
                // Handle changes
                print("Tone curve updated: \(points.count) points, gain: \(gain)")
            }
        }
    }
}
