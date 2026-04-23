# MTK Architecture

This directory contains Architecture Decision Records (ADRs) for the MTK Swift
package. ADRs document decisions that affect the package architecture, public
integration model, and enforcement boundaries.

## Records

- [Clinical Rendering ADR](ClinicalRenderingADR.md) - Metal-native clinical
  rendering, viewport resource sharing, presentation, explicit
  snapshot/export boundaries, and removal of SceneKit and `CGImage` display
  paths from the clinical architecture.
