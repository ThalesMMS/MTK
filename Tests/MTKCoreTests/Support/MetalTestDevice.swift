//
//  MetalTestDevice.swift
//  MTKCoreTests
//
//  Acquires the default Metal device or skips GPU-dependent tests when the host has no
//  available device.
//
//  Thales Matheus Mendonça Santos — April 2026
//

import Metal
import XCTest

func makeTestMetalDevice() throws -> any MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this test runner")
    }
    return device
}
