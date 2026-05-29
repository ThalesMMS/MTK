//
//  HangingProtocolDefinition.swift
//  MTKUI
//
//  Display-rule model for clinical viewport hanging protocols.
//

import Foundation
import MTKCore

/// Study role used by hanging protocol display sets.
public enum HangingProtocolStudyRole: String, Codable, Hashable, Sendable {
    case current
    case prior
}

/// Axis value used in hanging protocol definitions.
public enum HangingProtocolImagePlane: String, Codable, CaseIterable, Hashable, Sendable {
    case axial
    case coronal
    case sagittal

    public init(axis: MTKCore.Axis) {
        switch axis {
        case .axial:
            self = .axial
        case .coronal:
            self = .coronal
        case .sagittal:
            self = .sagittal
        }
    }

    public var axis: MTKCore.Axis {
        switch self {
        case .axial:
            return .axial
        case .coronal:
            return .coronal
        case .sagittal:
            return .sagittal
        }
    }
}

/// Viewport content requested by a hanging protocol slot.
public enum HangingProtocolViewportContent: Codable, Hashable, Sendable {
    case mpr(HangingProtocolImagePlane)
    case stack2D(HangingProtocolImagePlane)
    case volume3D

    public var mprAxis: MTKCore.Axis? {
        switch self {
        case .mpr(let plane), .stack2D(let plane):
            return plane.axis
        case .volume3D:
            return nil
        }
    }
}

/// Lightweight study descriptor used for hanging protocol matching.
public struct HangingProtocolStudyDescriptor: Codable, Hashable, Sendable {
    public var id: String?
    public var role: HangingProtocolStudyRole
    public var modality: String?
    public var anatomy: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?

    public init(id: String? = nil,
                role: HangingProtocolStudyRole,
                modality: String? = nil,
                anatomy: String? = nil,
                studyInstanceUID: String? = nil,
                seriesInstanceUID: String? = nil) {
        self.id = id
        self.role = role
        self.modality = modality
        self.anatomy = anatomy
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
    }

    public init(dataset: VolumeDataset,
                role: HangingProtocolStudyRole = .current) {
        let metadata = dataset.imageData.clinicalMetadata
        self.init(
            id: metadata?.seriesInstanceUID ?? metadata?.studyInstanceUID,
            role: role,
            modality: metadata?.modality,
            anatomy: metadata?.seriesDescription,
            studyInstanceUID: metadata?.studyInstanceUID,
            seriesInstanceUID: metadata?.seriesInstanceUID
        )
    }
}

/// Matching context containing the current study and any available priors.
public struct HangingProtocolContext: Codable, Hashable, Sendable {
    public var current: HangingProtocolStudyDescriptor
    public var priors: [HangingProtocolStudyDescriptor]

    public init(current: HangingProtocolStudyDescriptor,
                priors: [HangingProtocolStudyDescriptor] = []) {
        self.current = current
        self.priors = priors
    }

    public init(current dataset: VolumeDataset,
                priors: [HangingProtocolStudyDescriptor] = []) {
        self.init(current: HangingProtocolStudyDescriptor(dataset: dataset, role: .current),
                  priors: priors)
    }

    public static let empty = HangingProtocolContext(
        current: HangingProtocolStudyDescriptor(role: .current)
    )
}

/// Case-insensitive study filter for modality and anatomy matching.
public struct HangingProtocolStudyFilter: Codable, Hashable, Sendable {
    public var modalities: [String]
    public var anatomies: [String]

    public init(modalities: [String] = [],
                anatomies: [String] = []) {
        self.modalities = modalities
        self.anatomies = anatomies
    }

    public static let any = HangingProtocolStudyFilter()

    public func matches(_ study: HangingProtocolStudyDescriptor) -> Bool {
        matches(study.modality, patterns: modalities, containsAllowed: false) &&
        matches(study.anatomy, patterns: anatomies, containsAllowed: true)
    }

    private func matches(_ value: String?,
                         patterns: [String],
                         containsAllowed: Bool) -> Bool {
        let normalizedPatterns = patterns
            .map(Self.normalized)
            .filter { !$0.isEmpty }
        guard !normalizedPatterns.isEmpty else { return true }
        guard let normalizedValue = value.map(Self.normalized),
              !normalizedValue.isEmpty
        else { return false }

        return normalizedPatterns.contains { pattern in
            normalizedValue == pattern ||
            (containsAllowed && normalizedValue.contains(pattern))
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// Named display set referenced by hanging protocol viewport slots.
public struct HangingProtocolDisplaySetDefinition: Codable, Hashable, Sendable {
    public var id: String
    public var role: HangingProtocolStudyRole
    public var filter: HangingProtocolStudyFilter

    public init(id: String,
                role: HangingProtocolStudyRole,
                filter: HangingProtocolStudyFilter = .any) {
        self.id = id
        self.role = role
        self.filter = filter
    }
}

/// One viewport slot requested by a hanging protocol layout.
public struct HangingProtocolViewportDefinition: Codable, Hashable, Sendable {
    public var slot: Int
    public var displaySetID: String
    public var content: HangingProtocolViewportContent

    public init(slot: Int,
                displaySetID: String,
                content: HangingProtocolViewportContent) {
        self.slot = slot
        self.displaySetID = displaySetID
        self.content = content
    }
}

/// Concrete slot layout for a matched hanging protocol rule.
public struct HangingProtocolLayoutDefinition: Codable, Hashable, Sendable {
    public var screenLayout: MPRScreenLayout
    public var viewports: [HangingProtocolViewportDefinition]

    public init(screenLayout: MPRScreenLayout = .defaultLayout,
                viewports: [HangingProtocolViewportDefinition]) {
        self.screenLayout = screenLayout
        self.viewports = viewports
    }
}

/// Rule that selects a layout when study filters match.
public struct HangingProtocolRule: Codable, Hashable, Sendable {
    public var id: String
    public var priority: Int
    public var currentFilter: HangingProtocolStudyFilter
    public var requiredPriorFilter: HangingProtocolStudyFilter?
    public var layout: HangingProtocolLayoutDefinition

    public init(id: String,
                priority: Int = 0,
                currentFilter: HangingProtocolStudyFilter = .any,
                requiredPriorFilter: HangingProtocolStudyFilter? = nil,
                layout: HangingProtocolLayoutDefinition) {
        self.id = id
        self.priority = priority
        self.currentFilter = currentFilter
        self.requiredPriorFilter = requiredPriorFilter
        self.layout = layout
    }
}

/// Declarative hanging protocol definition consumed by MTKUI.
public struct HangingProtocolDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var displaySets: [HangingProtocolDisplaySetDefinition]
    public var rules: [HangingProtocolRule]

    public init(id: String,
                displayName: String,
                displaySets: [HangingProtocolDisplaySetDefinition],
                rules: [HangingProtocolRule]) {
        self.id = id
        self.displayName = displayName
        self.displaySets = displaySets
        self.rules = rules
    }

    public static func parse(json data: Data,
                             decoder: JSONDecoder = JSONDecoder()) throws -> HangingProtocolDefinition {
        try decoder.decode(HangingProtocolDefinition.self, from: data)
    }

    public func serializedJSON(prettyPrinted: Bool = true,
                               encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }
}

/// Resolved display set selected for a concrete study.
public struct HangingProtocolResolvedDisplaySet: Hashable, Sendable {
    public var id: String
    public var role: HangingProtocolStudyRole
    public var study: HangingProtocolStudyDescriptor
}

/// Resolved viewport slot ready to mount in a grid.
public struct HangingProtocolResolvedViewport: Hashable, Sendable {
    public var slot: Int
    public var displaySetID: String
    public var studyRole: HangingProtocolStudyRole
    public var studyID: String?
    public var content: HangingProtocolViewportContent
}

/// Resolved layout returned by the hanging protocol engine.
public struct HangingProtocolResolvedLayout: Hashable, Sendable {
    public var definitionID: String
    public var ruleID: String
    public var screenLayout: MPRScreenLayout
    public var viewports: [HangingProtocolResolvedViewport]
}

/// Matches hanging protocol definitions against current/prior study context.
public struct HangingProtocolEngine: Sendable {
    public init() {}

    public func resolve(_ definition: HangingProtocolDefinition,
                        context: HangingProtocolContext) -> HangingProtocolResolvedLayout? {
        let orderedRules = definition.rules.enumerated().sorted { lhs, rhs in
            if lhs.element.priority == rhs.element.priority {
                return lhs.offset < rhs.offset
            }
            return lhs.element.priority > rhs.element.priority
        }

        for rule in orderedRules.map(\.element) {
            guard rule.currentFilter.matches(context.current),
                  rule.requiredPriorFilter.map({ priorFilter in
                      context.priors.contains { priorFilter.matches($0) }
                  }) ?? true,
                  let resolved = resolve(rule: rule,
                                         definition: definition,
                                         context: context)
            else { continue }
            return resolved
        }
        return nil
    }

    private func resolve(rule: HangingProtocolRule,
                         definition: HangingProtocolDefinition,
                         context: HangingProtocolContext) -> HangingProtocolResolvedLayout? {
        let displaySets = resolveDisplaySets(definition.displaySets, context: context)
        var viewports: [HangingProtocolResolvedViewport] = []
        for viewport in rule.layout.viewports.sorted(by: { $0.slot < $1.slot }) {
            guard (1...3).contains(viewport.slot),
                  let displaySet = displaySets[viewport.displaySetID]
            else { return nil }
            viewports.append(
                HangingProtocolResolvedViewport(
                    slot: viewport.slot,
                    displaySetID: viewport.displaySetID,
                    studyRole: displaySet.role,
                    studyID: displaySet.study.id,
                    content: viewport.content
                )
            )
        }
        guard !viewports.isEmpty else { return nil }
        return HangingProtocolResolvedLayout(
            definitionID: definition.id,
            ruleID: rule.id,
            screenLayout: rule.layout.screenLayout,
            viewports: viewports
        )
    }

    private func resolveDisplaySets(_ definitions: [HangingProtocolDisplaySetDefinition],
                                    context: HangingProtocolContext) -> [String: HangingProtocolResolvedDisplaySet] {
        var resolved: [String: HangingProtocolResolvedDisplaySet] = [:]
        for definition in definitions {
            switch definition.role {
            case .current:
                guard definition.filter.matches(context.current) else { continue }
                resolved[definition.id] = HangingProtocolResolvedDisplaySet(
                    id: definition.id,
                    role: .current,
                    study: context.current
                )
            case .prior:
                guard let prior = context.priors.first(where: { definition.filter.matches($0) }) else {
                    continue
                }
                resolved[definition.id] = HangingProtocolResolvedDisplaySet(
                    id: definition.id,
                    role: .prior,
                    study: prior
                )
            }
        }
        return resolved
    }
}
