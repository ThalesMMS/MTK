import Foundation

public struct ClinicalVideoDimensions: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public struct ClinicalVideoDisplayState: Equatable, Sendable {
    public var title: String?
    public var codecLabel: String
    public var dimensions: ClinicalVideoDimensions?
    public var frameCount: Int
    public var frameRate: Double?
    public var durationSeconds: Double?
    public var streamByteCount: Int
    public var streamURL: URL?

    public init(
        title: String? = nil,
        codecLabel: String,
        dimensions: ClinicalVideoDimensions? = nil,
        frameCount: Int,
        frameRate: Double? = nil,
        durationSeconds: Double? = nil,
        streamByteCount: Int,
        streamURL: URL? = nil
    ) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.codecLabel = codecLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Video"
        if let dimensions, dimensions.columns > 0, dimensions.rows > 0 {
            self.dimensions = dimensions
        } else {
            self.dimensions = nil
        }
        self.frameCount = max(0, frameCount)
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            self.frameRate = frameRate
        } else {
            self.frameRate = nil
        }
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            self.durationSeconds = durationSeconds
        } else if let frameRate, frameRate.isFinite, frameRate > 0, frameCount > 0 {
            self.durationSeconds = Double(frameCount) / frameRate
        } else {
            self.durationSeconds = nil
        }
        self.streamByteCount = max(0, streamByteCount)
        self.streamURL = streamURL
    }

    public var isPlayable: Bool {
        streamURL != nil && streamByteCount > 0
    }

    public var dimensionsLabel: String? {
        guard let dimensions else { return nil }
        return "\(dimensions.columns) x \(dimensions.rows)"
    }

    public var frameRateLabel: String? {
        guard let frameRate else { return nil }
        return String(format: "%.3g fps", frameRate)
    }

    public var durationLabel: String? {
        guard let durationSeconds else { return nil }
        return String(format: "%.3g s", durationSeconds)
    }
}

#if canImport(SwiftUI) && canImport(AVKit) && (os(iOS) || os(macOS))
import AVKit
import SwiftUI

public struct ClinicalVideoView: View {
    private let state: ClinicalVideoDisplayState

    public init(state: ClinicalVideoDisplayState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = state.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ZStack {
                if let streamURL = state.streamURL {
                    VideoPlayer(player: AVPlayer(url: streamURL))
                } else {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 180)
            .frame(maxWidth: .infinity)
            .background(Color.black)

            metadataStrip
        }
        .padding(10)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ClinicalVideoView")
    }

    private var metadataStrip: some View {
        HStack(spacing: 12) {
            metadataText(state.codecLabel)
            if let dimensionsLabel = state.dimensionsLabel {
                metadataText(dimensionsLabel)
            }
            if state.frameCount > 0 {
                metadataText("\(state.frameCount) frames")
            }
            if let frameRateLabel = state.frameRateLabel {
                metadataText(frameRateLabel)
            }
            if let durationLabel = state.durationLabel {
                metadataText(durationLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataText(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
    }
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
