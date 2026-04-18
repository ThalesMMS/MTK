//
//  MetalVolumeRenderingAdapter+Testing.swift
//  MTK
//
//  Test-only introspection helpers for MetalVolumeRenderingAdapter.
//
//  Thales Matheus Mendonça Santos — April 2026

extension MetalVolumeRenderingAdapter {
    @_spi(Testing)
    public var debugOverrides: Overrides { overrides }

    @_spi(Testing)
    public var debugLastSnapshot: RenderSnapshot? { lastSnapshot }

    @_spi(Testing)
    public var debugCurrentPreset: VolumeRenderingPreset? { currentPreset }
}
