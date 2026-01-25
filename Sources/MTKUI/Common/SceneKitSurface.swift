import CoreGraphics
import SceneKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public final class SceneKitSurface: RenderSurface {
    public let sceneView: SCNView

    public init(sceneView: SCNView = SCNView()) {
        self.sceneView = sceneView
    }

    public var view: PlatformView { sceneView }

    public func display(_ image: CGImage) {
        _ = image
    }

    public func setContentScale(_ scale: CGFloat) {
#if os(iOS)
        sceneView.contentScaleFactor = scale
#elseif os(macOS)
        sceneView.layer?.contentsScale = scale
#endif
    }
}
