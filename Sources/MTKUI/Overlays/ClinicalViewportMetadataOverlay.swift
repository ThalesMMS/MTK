import Foundation
import MTKCore

public struct ClinicalViewportMetadataOverlaySettings: Equatable, Sendable {
    public var isVisible: Bool
    public var showsSubjectName: Bool
    public var showsStudyTitle: Bool
    public var showsSeriesTitle: Bool
    public var showsTechnicalText: Bool
    public var showsPixelValue: Bool
    public var showsQuantitativeValues: Bool
    public var showsDoseValues: Bool

    public init(isVisible: Bool = true,
                showsSubjectName: Bool = true,
                showsStudyTitle: Bool = true,
                showsSeriesTitle: Bool = true,
                showsTechnicalText: Bool = true,
                showsPixelValue: Bool = true,
                showsQuantitativeValues: Bool = true,
                showsDoseValues: Bool = true) {
        self.isVisible = isVisible
        self.showsSubjectName = showsSubjectName
        self.showsStudyTitle = showsStudyTitle
        self.showsSeriesTitle = showsSeriesTitle
        self.showsTechnicalText = showsTechnicalText
        self.showsPixelValue = showsPixelValue
        self.showsQuantitativeValues = showsQuantitativeValues
        self.showsDoseValues = showsDoseValues
    }

    public static let `default` = ClinicalViewportMetadataOverlaySettings()
}

public struct ClinicalViewportMetadataSample: Equatable, Sendable {
    public var intensity: VolumeIntensitySample?
    public var scalarSamples: [VolumeScalarSample]
    public var doseSamples: [RTDoseSample]

    public init(intensity: VolumeIntensitySample? = nil,
                scalarSamples: [VolumeScalarSample] = [],
                doseSamples: [RTDoseSample] = []) {
        self.intensity = intensity
        self.scalarSamples = scalarSamples
        self.doseSamples = doseSamples
    }

    public init(pickResult: VolumePickResult,
                doseSamples: [RTDoseSample] = []) {
        self.init(intensity: pickResult.intensity,
                  scalarSamples: pickResult.scalarSamples,
                  doseSamples: doseSamples)
    }

    public func displayLines(settings: ClinicalViewportMetadataOverlaySettings) -> [String] {
        guard settings.isVisible else { return [] }

        var lines: [String] = []
        if settings.showsPixelValue, let intensity {
            lines.append("Pixel: \(intensity.storedScalar)")
        }

        if settings.showsQuantitativeValues {
            let values = scalarSamples.compactMap(\.quantitativeValue)
            for value in values {
                let label = safeLabel(value.legendTitle) ??
                    safeLabel(value.quantityDefinitions.compactMap(\.displayText).first) ??
                    "Value"
                lines.append("\(label): \(formatted(value.value))\(unitSuffix(value.unitsLabel))")
            }
        }

        if settings.showsDoseValues {
            for (index, sample) in doseSamples.enumerated() {
                let label = doseSamples.count > 1 ? "Dose \(index + 1)" : "Dose"
                lines.append("\(label): \(formatted(sample.doseValue))\(unitSuffix(sample.doseUnits))")
            }
        }

        return lines
    }

    private func safeLabel(_ rawValue: String?) -> String? {
        ClinicalDisplayTextSanitizer.safeSeriesTitle(rawValue)
    }

    private func unitSuffix(_ rawValue: String?) -> String {
        guard let unit = ClinicalDisplayTextSanitizer.safeSeriesTitle(rawValue) else {
            return ""
        }
        return " \(unit)"
    }

    private func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "0.00" }
        return String(format: "%.2f", value)
    }
}
