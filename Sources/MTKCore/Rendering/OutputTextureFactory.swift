import Metal

enum OutputTextureFactory {
    static let defaultPixelFormat: MTLPixelFormat = .bgra8Unorm
    static let renderTargetUsage: MTLTextureUsage = [.shaderWrite, .shaderRead, .renderTarget, .pixelFormatView]
    static let shaderUsage: MTLTextureUsage = [.shaderWrite, .shaderRead]

    static func descriptor(width: Int,
                           height: Int,
                           pixelFormat: MTLPixelFormat = defaultPixelFormat,
                           usage: MTLTextureUsage = renderTargetUsage,
                           storageMode: MTLStorageMode = .private) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        return descriptor
    }

    static func makeTexture(device: any MTLDevice,
                            width: Int,
                            height: Int,
                            label: String,
                            pixelFormat: MTLPixelFormat = defaultPixelFormat,
                            usage: MTLTextureUsage = renderTargetUsage,
                            storageMode: MTLStorageMode = .private) -> (any MTLTexture)? {
        let descriptor = descriptor(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            usage: usage,
            storageMode: storageMode
        )
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    static func matchesPrivateBGRAOutput(_ texture: any MTLTexture,
                                         width: Int,
                                         height: Int,
                                         device: (any MTLDevice)? = nil,
                                         requiredUsage: MTLTextureUsage = renderTargetUsage) -> Bool {
        if let device, texture.device !== device {
            return false
        }
        return texture.textureType == .type2D
            && texture.width == width
            && texture.height == height
            && texture.pixelFormat == defaultPixelFormat
            && texture.storageMode == .private
            && texture.usage.isSuperset(of: requiredUsage)
    }
}
