//
//  MTKCoreResourceBundle.swift
//  MTK
//
//  Exposes MTKCore's SwiftPM resource bundle (Bundle.module) to test targets.
//
//  Thales Matheus Mendonca Santos — February 2026
//

import Foundation

public enum MTKCoreResourceBundle {
    public static var bundle: Bundle { Bundle.module }
}
