import Foundation
import SwiftUI

public struct TwoDHUDSettings: Equatable, Sendable {
    public var showsSubjectName: Bool
    public var showsSeriesTitle: Bool
    public var showsTechnicalText: Bool
    public var showsOrientationMarkers: Bool
    public var showsCenterOrientationMarker: Bool
    public var showsAxisBadge: Bool

    public init(showsSubjectName: Bool = true,
                showsSeriesTitle: Bool = true,
                showsTechnicalText: Bool = true,
                showsOrientationMarkers: Bool = true,
                showsCenterOrientationMarker: Bool = true,
                showsAxisBadge: Bool = true) {
        self.showsSubjectName = showsSubjectName
        self.showsSeriesTitle = showsSeriesTitle
        self.showsTechnicalText = showsTechnicalText
        self.showsOrientationMarkers = showsOrientationMarkers
        self.showsCenterOrientationMarker = showsCenterOrientationMarker
        self.showsAxisBadge = showsAxisBadge
    }

    public static let `default` = TwoDHUDSettings()
}

public struct Clinical2DHUDOverlay: View {
    private let state: Clinical2DViewportOverlayState
    private let style: any VolumetricUIStyle

    public init(state: Clinical2DViewportOverlayState,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.state = state
        self.style = style
    }

    public var body: some View {
        ZStack {
            hudBlocks
            centerOrientationMarker
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Clinical2DHUDOverlay")
    }

    private var hudBlocks: some View {
        VStack {
            HStack(alignment: .top) {
                annotationBlock(lines: state.topLeadingLines, alignment: .leading)
                Spacer(minLength: 16)
                annotationBlock(lines: state.topTrailingLines, alignment: .trailing)
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                annotationBlock(lines: state.bottomLeadingLines, alignment: .leading)
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 6) {
                    annotationBlock(lines: state.bottomTrailingLines, alignment: .trailing)
                    axisBadge
                }
            }
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var centerOrientationMarker: some View {
        if state.hudSettings.showsCenterOrientationMarker {
            VStack {
                hudText(state.orientationLabels.top)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(style.overlayBackground,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var axisBadge: some View {
        if state.hudSettings.showsAxisBadge {
            hudText(state.axis.clinicalDisplayName)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(style.overlayBackground,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    @ViewBuilder
    private func annotationBlock(lines: [String], alignment: HorizontalAlignment) -> some View {
        if !lines.isEmpty {
            VStack(alignment: alignment, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    hudText(line)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(style.overlayBackground,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func hudText(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(style.overlayForeground)
            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
    }
}
