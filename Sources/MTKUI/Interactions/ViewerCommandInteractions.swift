//
//  ViewerCommandInteractions.swift
//  MTKUI
//
//  Keyboard and context-menu bridging for ViewerCommandDescriptor
//  (issue #1213): hosts attach local keyboard shortcuts and pane-level
//  context menus from the same command model used by toolbars and app
//  menus. Touch-only iPhone use is unaffected — shortcuts only fire from
//  hardware keyboards and context menus from long-press/right-click.
//

import SwiftUI

extension View {
    /// Binds local keyboard shortcuts for every command that defines a key
    /// equivalent (hardware keyboards on iPadOS, all keyboards on macOS).
    public func viewerKeyboardCommands(
        _ commands: [ViewerCommandDescriptor] = ViewerCommandDescriptor.defaultViewerCommands,
        onCommand: @escaping (ViewerCommandID) -> Void
    ) -> some View {
        background {
            ForEach(commands.filter { $0.keyboardShortcut != nil }) { command in
                Button(command.title) { onCommand(command.id) }
                    .keyboardShortcut(command.keyboardShortcut ?? KeyboardShortcut(KeyEquivalent(" ")))
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Attaches a pane-level context menu (right-click on macOS/pointer,
    /// long-press on touch) listing the given viewer commands.
    public func viewerPaneContextMenu(
        _ commands: [ViewerCommandDescriptor] = ViewerCommandDescriptor.defaultViewerCommands,
        onCommand: @escaping (ViewerCommandID) -> Void
    ) -> some View {
        contextMenu {
            ForEach(commands) { command in
                Button {
                    onCommand(command.id)
                } label: {
                    Label(command.title, systemImage: command.systemImage)
                }
                .accessibilityIdentifier("\(command.accessibilityIdentifier).contextMenu")
            }
        }
    }

    /// Pointer hover highlight for chrome controls: subtly raises opacity
    /// while hovering. No-op for touch-only interaction.
    public func viewerHoverHighlight() -> some View {
        modifier(ViewerHoverHighlightModifier())
    }
}

private struct ViewerHoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
            )
            .onHover { isHovering = $0 }
    }
}
