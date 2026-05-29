import Foundation

public struct KeyImageReference: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var referencedSOPClassUID: String?
    public var referencedSOPInstanceUID: String
    public var referencedFrameNumbers: [Int]

    public init(studyInstanceUID: String? = nil,
                seriesInstanceUID: String? = nil,
                referencedSOPClassUID: String? = nil,
                referencedSOPInstanceUID: String,
                referencedFrameNumbers: [Int] = []) {
        self.studyInstanceUID = Self.cleanOptional(studyInstanceUID)
        self.seriesInstanceUID = Self.cleanOptional(seriesInstanceUID)
        self.referencedSOPClassUID = Self.cleanOptional(referencedSOPClassUID)
        self.referencedSOPInstanceUID = Self.cleanRequired(referencedSOPInstanceUID)
        self.referencedFrameNumbers = referencedFrameNumbers.filter { $0 > 0 }.sorted()
    }

    public var id: String {
        [
            studyInstanceUID ?? "",
            seriesInstanceUID ?? "",
            referencedSOPInstanceUID,
            referencedFrameNumbers.map(String.init).joined(separator: ".")
        ].joined(separator: "|")
    }
}

public struct LoadedKeyImageInstance: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var sopClassUID: String?
    public var sopInstanceUID: String
    public var sliceIndex: Int
    public var instanceNumber: Int?
    public var displayName: String?

    public init(studyInstanceUID: String? = nil,
                seriesInstanceUID: String? = nil,
                sopClassUID: String? = nil,
                sopInstanceUID: String,
                sliceIndex: Int,
                instanceNumber: Int? = nil,
                displayName: String? = nil) {
        self.studyInstanceUID = KeyImageReference.cleanOptional(studyInstanceUID)
        self.seriesInstanceUID = KeyImageReference.cleanOptional(seriesInstanceUID)
        self.sopClassUID = KeyImageReference.cleanOptional(sopClassUID)
        self.sopInstanceUID = KeyImageReference.cleanRequired(sopInstanceUID)
        self.sliceIndex = max(sliceIndex, 0)
        self.instanceNumber = instanceNumber
        self.displayName = KeyImageReference.cleanOptional(displayName)
    }

    public var id: String {
        [
            studyInstanceUID ?? "",
            seriesInstanceUID ?? "",
            sopInstanceUID,
            String(sliceIndex)
        ].joined(separator: "|")
    }

    public var navigationLabel: String {
        displayName ?? "Image \(sliceIndex + 1)"
    }
}

public struct ResolvedKeyImage: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var reference: KeyImageReference
    public var instance: LoadedKeyImageInstance

    public init(reference: KeyImageReference, instance: LoadedKeyImageInstance) {
        self.reference = reference
        self.instance = instance
    }

    public var id: String {
        "\(reference.id)|\(instance.id)"
    }

    public var sliceIndex: Int {
        instance.sliceIndex
    }

    public var navigationLabel: String {
        instance.navigationLabel
    }
}

public struct KeyImageNavigationState: Codable, Equatable, Sendable {
    public private(set) var references: [KeyImageReference]
    public private(set) var loadedInstances: [LoadedKeyImageInstance]
    public private(set) var resolvedImages: [ResolvedKeyImage]
    public private(set) var selectedImageID: ResolvedKeyImage.ID?
    public var isFilterEnabled: Bool

    public init(references: [KeyImageReference] = [],
                loadedInstances: [LoadedKeyImageInstance] = [],
                isFilterEnabled: Bool = false,
                selectedImageID: ResolvedKeyImage.ID? = nil) {
        self.references = Self.unique(references)
        self.loadedInstances = Self.unique(loadedInstances)
        self.resolvedImages = Self.resolve(references: self.references,
                                           loadedInstances: self.loadedInstances)
        self.isFilterEnabled = isFilterEnabled && !resolvedImages.isEmpty
        if let selectedImageID,
           resolvedImages.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = selectedImageID
        } else {
            self.selectedImageID = resolvedImages.first?.id
        }
    }

    public var hasResolvedImages: Bool {
        !resolvedImages.isEmpty
    }

    public var selectedImage: ResolvedKeyImage? {
        guard let selectedImageID else { return nil }
        return resolvedImages.first { $0.id == selectedImageID }
    }

    public var selectedImageIndex: Int? {
        guard let selectedImageID else { return nil }
        return resolvedImages.firstIndex { $0.id == selectedImageID }
    }

    public var visibleSliceIndices: [Int] {
        resolvedImages.map(\.sliceIndex)
    }

    public mutating func setFilterEnabled(_ enabled: Bool) {
        isFilterEnabled = enabled && hasResolvedImages
        if isFilterEnabled, selectedImageID == nil {
            selectedImageID = resolvedImages.first?.id
        }
    }

    public mutating func selectImage(id: ResolvedKeyImage.ID?) {
        guard let id else {
            selectedImageID = nil
            return
        }
        guard resolvedImages.contains(where: { $0.id == id }) else { return }
        selectedImageID = id
    }

    @discardableResult
    public mutating func selectImage(containingSliceIndex sliceIndex: Int) -> ResolvedKeyImage? {
        guard let image = resolvedImages.first(where: { $0.sliceIndex == sliceIndex }) else {
            return nil
        }
        selectedImageID = image.id
        return image
    }

    @discardableResult
    public mutating func selectNext(wrapping: Bool = true) -> ResolvedKeyImage? {
        selectRelative(offset: 1, wrapping: wrapping)
    }

    @discardableResult
    public mutating func selectPrevious(wrapping: Bool = true) -> ResolvedKeyImage? {
        selectRelative(offset: -1, wrapping: wrapping)
    }

    @discardableResult
    public mutating func selectRelative(offset: Int, wrapping: Bool = true) -> ResolvedKeyImage? {
        guard !resolvedImages.isEmpty, offset != 0 else { return selectedImage }
        let currentIndex = selectedImageIndex ?? (offset > 0 ? -1 : resolvedImages.count)
        let candidate = currentIndex + offset
        let resolvedIndex: Int
        if wrapping {
            resolvedIndex = Self.wrappedIndex(candidate, count: resolvedImages.count)
        } else {
            resolvedIndex = min(max(candidate, 0), resolvedImages.count - 1)
        }
        let image = resolvedImages[resolvedIndex]
        selectedImageID = image.id
        return image
    }

    @discardableResult
    public mutating func selectRelative(toSliceIndex sliceIndex: Int,
                                        offset: Int,
                                        wrapping: Bool = true) -> ResolvedKeyImage? {
        guard !resolvedImages.isEmpty, offset != 0 else { return selectedImage }
        let direction = offset > 0 ? 1 : -1
        var currentSlice = sliceIndex
        var selected: ResolvedKeyImage?
        for _ in 0..<abs(offset) {
            selected = selectAdjacent(toSliceIndex: currentSlice,
                                      direction: direction,
                                      wrapping: wrapping)
            if let selected {
                currentSlice = selected.sliceIndex
            }
        }
        return selected
    }
}

public extension KeyImageNavigationState {
    static func resolve(references: [KeyImageReference],
                        loadedInstances: [LoadedKeyImageInstance]) -> [ResolvedKeyImage] {
        let orderedInstances = loadedInstances.sorted { lhs, rhs in
            if lhs.sliceIndex != rhs.sliceIndex {
                return lhs.sliceIndex < rhs.sliceIndex
            }
            return lhs.sopInstanceUID < rhs.sopInstanceUID
        }
        var resolved: [ResolvedKeyImage] = []
        for reference in unique(references) {
            guard let instance = orderedInstances.first(where: { matches(reference: reference, instance: $0) }) else {
                continue
            }
            let image = ResolvedKeyImage(reference: reference, instance: instance)
            if !resolved.contains(where: { $0.id == image.id }) {
                resolved.append(image)
            }
        }
        return resolved.sorted { lhs, rhs in
            if lhs.sliceIndex != rhs.sliceIndex {
                return lhs.sliceIndex < rhs.sliceIndex
            }
            return lhs.reference.referencedSOPInstanceUID < rhs.reference.referencedSOPInstanceUID
        }
    }
}

private extension KeyImageNavigationState {
    static func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
        var seen: Set<String> = []
        var result: [T] = []
        for value in values where seen.insert(value.id).inserted {
            result.append(value)
        }
        return result
    }

    static func matches(reference: KeyImageReference, instance: LoadedKeyImageInstance) -> Bool {
        guard !reference.referencedSOPInstanceUID.isEmpty,
              reference.referencedSOPInstanceUID == instance.sopInstanceUID else {
            return false
        }
        return optionalMatches(reference.studyInstanceUID, instance.studyInstanceUID) &&
            optionalMatches(reference.seriesInstanceUID, instance.seriesInstanceUID)
    }

    static func optionalMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    mutating func selectAdjacent(toSliceIndex sliceIndex: Int,
                                 direction: Int,
                                 wrapping: Bool) -> ResolvedKeyImage? {
        let image: ResolvedKeyImage?
        if direction > 0 {
            image = resolvedImages.first { $0.sliceIndex > sliceIndex }
                ?? (wrapping ? resolvedImages.first : nil)
        } else {
            image = resolvedImages.last { $0.sliceIndex < sliceIndex }
                ?? (wrapping ? resolvedImages.last : nil)
        }
        guard let image else { return selectedImage }
        selectedImageID = image.id
        return image
    }

    static func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }
}

fileprivate extension KeyImageReference {
    static func cleanRequired(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanOptional(_ value: String?) -> String? {
        guard let cleaned = value
            .map(cleanRequired)?
            .prefix(160),
            !cleaned.isEmpty else {
            return nil
        }
        return String(cleaned)
    }
}
