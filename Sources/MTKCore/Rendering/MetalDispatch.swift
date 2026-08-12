import Metal

enum MetalDispatch {
    static func threadgroups(for threadsPerGrid: MTLSize,
                             threadsPerThreadgroup: MTLSize) -> MTLSize {
        let threadgroupWidth = max(1, threadsPerThreadgroup.width)
        let threadgroupHeight = max(1, threadsPerThreadgroup.height)
        let threadgroupDepth = max(1, threadsPerThreadgroup.depth)
        return MTLSize(
            width: (threadsPerGrid.width + threadgroupWidth - 1) / threadgroupWidth,
            height: (threadsPerGrid.height + threadgroupHeight - 1) / threadgroupHeight,
            depth: (threadsPerGrid.depth + threadgroupDepth - 1) / threadgroupDepth
        )
    }

    /// Shrinks a threadgroup so no dimension asks for more threads than the grid has.
    ///
    /// The threadgroup shape comes from the pipeline's limits, not from the work: a
    /// 2x2x1 volume is dispatched with a 32x32x1 threadgroup, so 1020 of the 1024
    /// threads exist only to take the out-of-range early exit. That is wasteful on its
    /// own, and for a kernel that partitions threadgroup memory by
    /// `threads_per_threadgroup` it also makes correctness depend on the runtime
    /// reporting the *clamped* size of a non-uniform threadgroup rather than the
    /// dispatched one — a detail the host does not control. Clamping here covers the
    /// grid exactly and leaves nothing for that detail to decide.
    ///
    /// The threadgroup *count* is unchanged: a grid smaller than the threadgroup
    /// rounds up to one threadgroup either way.
    static func clamped(threadsPerThreadgroup: MTLSize, to threadsPerGrid: MTLSize) -> MTLSize {
        func fit(_ threads: Int, _ grid: Int) -> Int {
            max(1, min(max(1, threads), max(1, grid)))
        }
        return MTLSize(width: fit(threadsPerThreadgroup.width, threadsPerGrid.width),
                       height: fit(threadsPerThreadgroup.height, threadsPerGrid.height),
                       depth: fit(threadsPerThreadgroup.depth, threadsPerGrid.depth))
    }

    /// Encodes the dispatch and returns the threadgroup shape actually used, so callers
    /// that report their dispatch describe what ran rather than what they asked for.
    @discardableResult
    static func dispatch(encoder: any MTLComputeCommandEncoder,
                         threadsPerGrid: MTLSize,
                         threadsPerThreadgroup: MTLSize,
                         featureFlags: FeatureFlags) -> MTLSize {
        let effective = clamped(threadsPerThreadgroup: threadsPerThreadgroup, to: threadsPerGrid)

        if featureFlags.contains(.nonUniformThreadgroups) {
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: effective)
        } else {
            encoder.dispatchThreadgroups(
                threadgroups(for: threadsPerGrid, threadsPerThreadgroup: effective),
                threadsPerThreadgroup: effective
            )
        }

        return effective
    }

    @discardableResult
    static func dispatch(encoder: any MTLComputeCommandEncoder,
                         threadsPerGrid: MTLSize,
                         configuration: ThreadgroupDispatchConfiguration,
                         featureFlags: FeatureFlags) -> MTLSize {
        dispatch(
            encoder: encoder,
            threadsPerGrid: threadsPerGrid,
            threadsPerThreadgroup: configuration.threadsPerThreadgroup,
            featureFlags: featureFlags
        )
    }
}
