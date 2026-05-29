import Foundation

public struct ClinicalWaveformTrace: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let unitLabel: String?
    public let samplingFrequency: Double
    public let samples: [Int]

    public init(
        id: String,
        label: String,
        unitLabel: String? = nil,
        samplingFrequency: Double,
        samples: [Int]
    ) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unitLabel = unitLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.samplingFrequency = samplingFrequency.isFinite ? max(samplingFrequency, 0) : 0
        self.samples = samples
    }

    public var durationSeconds: Double {
        guard samplingFrequency > 0 else { return 0 }
        return Double(samples.count) / samplingFrequency
    }

    public var amplitudeRange: ClosedRange<Int>? {
        guard let minimum = samples.min(), let maximum = samples.max() else { return nil }
        return minimum...maximum
    }

    public func normalizedSamples(maximumCount: Int? = nil) -> [Double] {
        let values = downsampledSamples(maximumCount: maximumCount)
        let peak = max(values.map { abs(Double($0)) }.max() ?? 0, 1)
        return values.map { Double($0) / peak }
    }

    private func downsampledSamples(maximumCount: Int?) -> [Int] {
        guard let maximumCount, maximumCount > 0, samples.count > maximumCount else {
            return samples
        }
        return (0..<maximumCount).map { index in
            samples[min(samples.count - 1, index * samples.count / maximumCount)]
        }
    }
}

public struct ClinicalWaveformDisplayState: Equatable, Sendable {
    public var title: String?
    public var traces: [ClinicalWaveformTrace]

    public init(title: String? = nil, traces: [ClinicalWaveformTrace]) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.traces = traces
    }

    public var isEmpty: Bool {
        traces.allSatisfy(\.samples.isEmpty)
    }

    public var durationSeconds: Double {
        traces.map(\.durationSeconds).max() ?? 0
    }
}

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI

public struct ClinicalWaveformView: View {
    private let state: ClinicalWaveformDisplayState

    public init(state: ClinicalWaveformDisplayState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = state.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            waveformCanvas
        }
        .padding(10)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ClinicalWaveformView")
    }

    @ViewBuilder
    private var waveformCanvas: some View {
        if state.isEmpty {
            Text("No waveform data")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
        } else {
            Canvas { context, size in
                drawGrid(in: &context, size: size)
                for (index, trace) in state.traces.enumerated() where !trace.samples.isEmpty {
                    draw(trace: trace, index: index, traceCount: state.traces.count, in: &context, size: size)
                }
            }
            .frame(minHeight: max(96, CGFloat(state.traces.count) * 52))
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let gridColor = Color.white.opacity(0.12)
        var path = Path()
        let columns = 8
        let rows = max(2, state.traces.count * 2)
        for column in 0...columns {
            let x = size.width * CGFloat(column) / CGFloat(columns)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for row in 0...rows {
            let y = size.height * CGFloat(row) / CGFloat(rows)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
    }

    private func draw(
        trace: ClinicalWaveformTrace,
        index: Int,
        traceCount: Int,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let laneHeight = size.height / CGFloat(max(1, traceCount))
        let laneTop = laneHeight * CGFloat(index)
        let baseline = laneTop + laneHeight / 2
        let amplitude = max(8, laneHeight * 0.38)
        let values = trace.normalizedSamples(maximumCount: max(2, Int(size.width.rounded())))
        guard values.count >= 2 else { return }

        var path = Path()
        for (sampleIndex, value) in values.enumerated() {
            let x = size.width * CGFloat(sampleIndex) / CGFloat(values.count - 1)
            let y = baseline - CGFloat(value) * amplitude
            if sampleIndex == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(traceColor(index: index)), lineWidth: 1.4)

        let label = Text(trace.unitLabel.map { "\(trace.label) \($0)" } ?? trace.label)
            .font(.caption2.monospacedDigit())
            .foregroundColor(.white.opacity(0.82))
        context.draw(label, at: CGPoint(x: 6, y: laneTop + 12), anchor: .leading)
    }

    private func traceColor(index: Int) -> Color {
        let colors: [Color] = [.green, .cyan, .yellow, .orange, .mint, .pink]
        return colors[index % colors.count]
    }
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
