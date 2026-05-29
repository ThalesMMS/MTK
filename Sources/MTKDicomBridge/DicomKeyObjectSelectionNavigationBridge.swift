import DicomCore
import Foundation
import MTKUI

public enum DicomKeyObjectSelectionNavigationBridge {
    public static func makeState(from documents: [DicomSRDocument],
                                 loadedInstances: [LoadedKeyImageInstance],
                                 isFilterEnabled: Bool = false) -> KeyImageNavigationState {
        KeyImageNavigationState(
            references: makeReferences(from: documents),
            loadedInstances: loadedInstances,
            isFilterEnabled: isFilterEnabled
        )
    }

    public static func makeState(from document: DicomSRDocument,
                                 loadedInstances: [LoadedKeyImageInstance],
                                 isFilterEnabled: Bool = false) -> KeyImageNavigationState {
        makeState(from: [document],
                  loadedInstances: loadedInstances,
                  isFilterEnabled: isFilterEnabled)
    }

    public static func makeReferences(from documents: [DicomSRDocument]) -> [KeyImageReference] {
        documents.flatMap(\.keyObjectReferences).compactMap(makeReference(from:))
    }

    public static func makeLoadedInstances(from instances: [DicomSeriesImageInstance]) -> [LoadedKeyImageInstance] {
        instances.map {
            LoadedKeyImageInstance(
                studyInstanceUID: $0.studyInstanceUID,
                seriesInstanceUID: $0.seriesInstanceUID,
                sopClassUID: $0.sopClassUID,
                sopInstanceUID: $0.sopInstanceUID,
                sliceIndex: $0.sliceIndex,
                instanceNumber: $0.instanceNumber
            )
        }
    }
}

private extension DicomKeyObjectSelectionNavigationBridge {
    static func makeReference(from reference: DicomKeyObjectReference) -> KeyImageReference? {
        guard let sopInstanceUID = reference.referencedSOPInstanceUID else { return nil }
        return KeyImageReference(
            studyInstanceUID: reference.studyInstanceUID,
            seriesInstanceUID: reference.seriesInstanceUID,
            referencedSOPClassUID: reference.referencedSOPClassUID,
            referencedSOPInstanceUID: sopInstanceUID,
            referencedFrameNumbers: reference.referencedFrameNumbers
        )
    }
}
