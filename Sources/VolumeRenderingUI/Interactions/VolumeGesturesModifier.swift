//  VolumeGesturesModifier.swift
//  MTK
//  SwiftUI modifiers that forward user gestures to the volumetric controller.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

@MainActor
struct VolumeGesturesModifier: ViewModifier {
    @ObservedObject private var state: VolumeGestureState
    private let controller: VolumetricSceneController
    private let configuration: VolumeGestureConfiguration

    init(state: VolumeGestureState,
         controller: VolumetricSceneController,
         configuration: VolumeGestureConfiguration) {
        self.state = state
        self.controller = controller
        self.configuration = configuration
    }

    func body(content: Content) -> some View {
        let context = state.makeContext(merging: controller.gestureContext(using: state))
        content
            .simultaneousGesture(makeTranslationGesture(context: context))
            .simultaneousGesture(makeMagnificationGesture(context: context))
            .simultaneousGesture(makeRotationGesture(context: context))
    }

    private func makeTranslationGesture(context: VolumeGestureContext) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard configuration.allowsTranslation else { return }
                context.onTranslate(.volume, value.translation)
            }
            .onEnded { _ in context.onReset() }
    }

    private func makeMagnificationGesture(context: VolumeGestureContext) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard configuration.allowsZoom else { return }
                context.onZoom(value)
            }
    }

    private func makeRotationGesture(context: VolumeGestureContext) -> some Gesture {
        RotationGesture()
            .onChanged { radians in
                guard configuration.allowsRotation else { return }
                context.onRotate(.volume, radians)
            }
    }
}

public extension View {
    func volumeGestures(controller: VolumetricSceneController,
                        state: VolumeGestureState = VolumeGestureState(),
                        configuration: VolumeGestureConfiguration = .default) -> some View {
        modifier(VolumeGesturesModifier(state: state,
                                        controller: controller,
                                        configuration: configuration))
    }
}

#endif
