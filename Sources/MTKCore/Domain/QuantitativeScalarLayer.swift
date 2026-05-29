//
//  QuantitativeScalarLayer.swift
//  MTKCore
//
//  Quantitative metadata for scalar overlay layers.
//

import Foundation

public struct QuantitativeCodedConcept: Sendable, Equatable, Hashable {
    public var codeValue: String
    public var codingSchemeDesignator: String
    public var codeMeaning: String?

    public init(codeValue: String,
                codingSchemeDesignator: String,
                codeMeaning: String? = nil) {
        self.codeValue = codeValue
        self.codingSchemeDesignator = codingSchemeDesignator
        self.codeMeaning = codeMeaning
    }

    public var displayText: String {
        codeMeaning?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
            codeValue
    }
}

public struct QuantitativeQuantityDefinition: Sendable, Equatable, Hashable {
    public var conceptName: QuantitativeCodedConcept?
    public var conceptCode: QuantitativeCodedConcept?
    public var numericValue: Double?
    public var textValue: String?

    public init(conceptName: QuantitativeCodedConcept? = nil,
                conceptCode: QuantitativeCodedConcept? = nil,
                numericValue: Double? = nil,
                textValue: String? = nil) {
        self.conceptName = conceptName
        self.conceptCode = conceptCode
        self.numericValue = numericValue
        self.textValue = textValue
    }

    public var displayText: String? {
        conceptCode?.displayText ??
            conceptName?.displayText ??
            textValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct QuantitativeScalarLayerLegend: Sendable, Equatable, Identifiable {
    public var id: String { layerID }
    public var layerID: String
    public var title: String
    public var unitsLabel: String?
    public var physicalRange: ClosedRange<Double>

    public init(layerID: String,
                title: String,
                unitsLabel: String?,
                physicalRange: ClosedRange<Double>) {
        self.layerID = layerID
        self.title = title
        self.unitsLabel = unitsLabel
        self.physicalRange = physicalRange
    }
}

public struct QuantitativeScalarValue: Sendable, Equatable {
    public var value: Double
    public var units: QuantitativeCodedConcept?
    public var quantityDefinitions: [QuantitativeQuantityDefinition]
    public var physicalRange: ClosedRange<Double>
    public var legendTitle: String?

    public init(value: Double,
                units: QuantitativeCodedConcept?,
                quantityDefinitions: [QuantitativeQuantityDefinition],
                physicalRange: ClosedRange<Double>,
                legendTitle: String?) {
        self.value = value
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.physicalRange = physicalRange
        self.legendTitle = legendTitle
    }

    public var unitsLabel: String? {
        units?.displayText
    }
}

public struct QuantitativeScalarMapping: Sendable, Equatable {
    public var units: QuantitativeCodedConcept?
    public var quantityDefinitions: [QuantitativeQuantityDefinition]
    public var physicalRange: ClosedRange<Double>
    public var storedValueRange: ClosedRange<Int32>
    public var physicalValues: [Double]?
    public var legendTitle: String?

    public init(units: QuantitativeCodedConcept? = nil,
                quantityDefinitions: [QuantitativeQuantityDefinition] = [],
                physicalRange: ClosedRange<Double>,
                storedValueRange: ClosedRange<Int32>,
                physicalValues: [Double]? = nil,
                legendTitle: String? = nil) {
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.physicalRange = physicalRange
        self.storedValueRange = storedValueRange
        self.physicalValues = physicalValues
        self.legendTitle = legendTitle
    }

    public var unitsLabel: String? {
        units?.displayText
    }

    public var quantityLabel: String? {
        quantityDefinitions.compactMap(\.displayText).first
    }

    public func legend(forLayerID layerID: String) -> QuantitativeScalarLayerLegend {
        QuantitativeScalarLayerLegend(layerID: layerID,
                                      title: legendTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
                                          quantityLabel ??
                                          "Quantitative scalar",
                                      unitsLabel: unitsLabel,
                                      physicalRange: physicalRange)
    }

    public func sample(storedScalar: Int32, linearIndex: Int?) -> QuantitativeScalarValue? {
        guard let value = physicalValue(storedScalar: storedScalar, linearIndex: linearIndex) else {
            return nil
        }
        return QuantitativeScalarValue(value: value,
                                       units: units,
                                       quantityDefinitions: quantityDefinitions,
                                       physicalRange: physicalRange,
                                       legendTitle: legendTitle)
    }

    public func physicalValue(storedScalar: Int32, linearIndex: Int?) -> Double? {
        if let linearIndex,
           let physicalValues,
           physicalValues.indices.contains(linearIndex) {
            return physicalValues[linearIndex]
        }

        let storedLower = Double(storedValueRange.lowerBound)
        let storedUpper = Double(storedValueRange.upperBound)
        guard storedUpper > storedLower else {
            return physicalRange.lowerBound
        }
        let clamped = min(max(Double(storedScalar), storedLower), storedUpper)
        let t = (clamped - storedLower) / (storedUpper - storedLower)
        return physicalRange.lowerBound + (physicalRange.upperBound - physicalRange.lowerBound) * t
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
