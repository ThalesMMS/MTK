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

    static func dispatch(encoder: any MTLComputeCommandEncoder,
                         threadsPerGrid: MTLSize,
                         threadsPerThreadgroup: MTLSize,
                         featureFlags: FeatureFlags) {
        if featureFlags.contains(.nonUniformThreadgroups) {
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        } else {
            encoder.dispatchThreadgroups(
                threadgroups(for: threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup),
                threadsPerThreadgroup: threadsPerThreadgroup
            )
        }
    }

    static func dispatch(encoder: any MTLComputeCommandEncoder,
                         threadsPerGrid: MTLSize,
                         configuration: ThreadgroupDispatchConfiguration,
                         featureFlags: FeatureFlags) {
        dispatch(
            encoder: encoder,
            threadsPerGrid: threadsPerGrid,
            threadsPerThreadgroup: configuration.threadsPerThreadgroup,
            featureFlags: featureFlags
        )
    }
}
