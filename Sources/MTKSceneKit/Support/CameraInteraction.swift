//  CameraInteraction.swift
//  MTK
//  Protocols for SceneKit camera interaction bridging to the UI layer.
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import simd

public protocol VolumeCameraControlling: AnyObject {
    func orbit(by delta: SIMD2<Float>)
    func pan(by delta: SIMD2<Float>)
    func zoom(by factor: Float)
}

public final class VolumeCameraControllerStore {
    private var controllers: NSMapTable<AnyObject, AnyObject>

    public init() {
        controllers = NSMapTable<AnyObject, AnyObject>.weakToWeakObjects()
    }

    public func register(key: AnyObject, controller: VolumeCameraControlling) {
        controllers.setObject(controller, forKey: key)
    }

    public func controller(for key: AnyObject) -> VolumeCameraControlling? {
        controllers.object(forKey: key) as? VolumeCameraControlling
    }

    public func remove(key: AnyObject) {
        controllers.removeObject(forKey: key)
    }
}

