//
//  Sizeable.swift
//  Isis DICOM Viewer
//
//  Declara o protocolo Sizeable e auxiliares de layout de memória utilizados pelos uniforms dos materiais volumétricos.
//  Disponibiliza cálculos de tamanho e stride para coleções de tipos escalares e vetoriais, garantindo compatibilidade com Metal e SceneKit.
//  Thales Matheus Mendonça Santos - September 2025
//

import simd

public protocol Sizeable {}

public extension Sizeable {
    static var size: Int { MemoryLayout<Self>.size }
    static var stride: Int { MemoryLayout<Self>.stride }

    static func size(_ count: Int) -> Int {
        MemoryLayout<Self>.size * count
    }

    static func stride(_ count: Int) -> Int {
        MemoryLayout<Self>.stride * count
    }
}

// Legacy shader helpers still reference the lowercase spelling.
public typealias sizeable = Sizeable

extension Int32: Sizeable {}
extension Float: Sizeable {}
extension SIMD2: Sizeable where Scalar == Float {}
extension SIMD3: Sizeable where Scalar == Float {}
extension SIMD4: Sizeable where Scalar == Float {}
