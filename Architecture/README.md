# MTK Architecture

This directory contains Architecture Decision Records (ADRs) for the MTK Swift
package. ADRs document decisions that affect the package architecture, public
integration model, and enforcement boundaries.

## Records

- [Public API Contract](PublicAPI.md) - Stable, experimental, and internal API
  boundaries for downstream applications.
- [Clinical Rendering ADR](ClinicalRenderingADR.md) - Metal-native clinical
  rendering, viewport resource sharing, presentation, explicit
  snapshot/export boundaries, and removal of SceneKit and `CGImage` display
  paths from the clinical architecture.
- [Multi-Volume Registration And Resampling Plan](MultiVolumeRegistration.md) -
  Current v1 fusion boundaries and the v2 plan for explicit layer transforms,
  resampling, and registered clinical overlay workflows.

## Internal design notes

- [Rendering engine/service split notes](RenderingEngineSplit.md) - Internal-only
  documentation of the focused service boundaries extracted from
  `MTKRenderingEngine` and `VolumeResourceManager`.
