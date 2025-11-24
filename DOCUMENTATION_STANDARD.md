# Documentation standard — MTK
_Last updated: 2026-01-08_

Baseline rules for keeping MTK’s documentation accurate and lean. These apply to README updates, helper guides (like `BACKEND_RESOLVER_USAGE.md`), and DocC comments on public APIs.

## Audience and scope
- Primary readers: iOS/macOS engineers integrating MTK in SwiftUI/SceneKit apps.
- Modules covered: `MTKCore`, `MTKSceneKit`, `MTKUI`, and the build tooling that ships shaders/resources.

## Markdown guidelines
- Start with a short purpose sentence; avoid historical migration notes.
- Include “Last updated” and module/area when relevant.
- Structure sections around: what it does, how to use it, requirements/fixtures, and failure modes.
- Examples must reference real APIs that exist in `Sources/`; avoid placeholder types or missing assets.

## Public API documentation (DocC)
- Document every public type/method in `MTKUI` and `MTKSceneKit`; prioritize thread-safety, platform/Metal requirements, and side effects.
- For GPU-facing APIs (e.g., `MetalRaycaster`, `VolumeTextureFactory`, `VolumetricSceneController`), describe fallback behavior when Metal or MPS is unavailable.
- Keep code examples minimal and compilable; prefer `VolumetricSceneController`, `VolumetricSceneCoordinator`, and `VolumeDataset` in snippets.

## Code comments
- Explain why non-obvious logic exists (performance assumptions, Metal constraints, coordinate system choices).
- Note fallbacks or degradation paths (CPU paths in `MetalVolumeRenderingAdapter`, histogram paths in `MPSVolumeRenderer`).
- Avoid restating the obvious or duplicating type names.

## Testing and fixtures
- Call out external requirements (e.g., DICOM fixtures under `MTK-Demo/DICOM_Example` or GDCM vendor libs) so test expectations are clear.
- When tests skip in constrained environments (no Metal, missing fixtures), note that behavior in the relevant docs.

## Build and resources
- Mention the `MTKShaderPlugin` and `Tooling/Shaders/build_metallib.sh` flow whenever shaders are discussed; note the expected metallib name and fallback chain in `ShaderLibraryLoader`.
- If a feature depends on assets that are not committed (sample RAW volumes, DICOM examples), state it explicitly and point to where to place them.
