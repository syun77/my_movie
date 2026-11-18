import Metal
import Foundation

/// Integrates a fixed radial interval in linear premultiplied RGBA.
final class RadialBlurRenderer {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState

    struct Uniforms {
        var canvas: SIMD4<Float>
        var quality: SIMD4<Float>
    }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard let function = library.makeFunction(name: "radialBlur") else { throw MetalSceneRenderer.renderError }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func render(_ image: MTLTexture, effect: ImageEffects.RadialBlur, canvas: CGSize, padding: Double,
                reusing previous: MTLTexture?, commands: MTLCommandBuffer, jitter: Float = 0.35) throws -> MTLTexture {
        guard effect.isEnabled && effect.strength > 0 else { return image }
        let output: MTLTexture
        if let previous, previous !== image, previous.width == image.width, previous.height == image.height {
            output = previous
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: image.width, height: image.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw MetalSceneRenderer.renderError }
            output = texture
        }
        guard let encoder = commands.makeComputeCommandEncoder() else { throw MetalSceneRenderer.renderError }
        var uniforms = Uniforms(canvas: SIMD4(Float(canvas.width), Float(canvas.height), Float(padding), Float(effect.strength / 100)),
                                quality: SIMD4(Float(effect.centerX / 1920), Float(1 - effect.centerY / 1080), Float(effect.samples), jitter))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(MTLSize(width: image.width, height: image.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        return output
    }
}
