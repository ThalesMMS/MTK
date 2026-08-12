//
//  MTKCoreResourceBundle.swift
//  MTKCore
//
//  Exposes MTKCore's SwiftPM resource bundle (Bundle.module) to test targets.
//
//  Thales Matheus Mendonça Santos — February 2026
//

import Foundation

public enum MTKCoreResourceBundle {
    public static var bundle: Bundle { Bundle.module }
}
