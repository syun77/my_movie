import Foundation
import Metal

/// Reads the preceding chain surface and writes linear RGBA into the next shared surface.
final class SobelChromaticRenderer {
    private let pipeline: MTLComputePipelineState
    struct Uniforms {
        var canvas: SIMD4<Float>
        var offsets: SIMD4<Float>
        var settings: SIMD4<Float>
        var edgeColor: SIMD4<Float>
    }
    init(device: MTLDevice, library: MTLLibrary) throws {
        guard let function = library.makeFunction(name: "sobelChromatic") else { throw MetalSceneRenderer.renderError }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func render(_ image: MTLTexture, effect: ImageEffects.SobelChromatic, localTime: Double,
                canvas: CGSize, padding: Double, output: MTLTexture, commands: MTLCommandBuffer) throws -> MTLTexture {
        guard effect.isEnabled && effect.amount > 0 else { return image }
        let sample = effect.sample(at: localTime)
        func linear(_ value: Double) -> Float {
            Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        let scale = canvas.height / 1080
        var uniforms = Uniforms(
            canvas: SIMD4(Float(canvas.width), Float(canvas.height), Float(padding), Float(scale)),
            offsets: SIMD4(Float(sample.negativeOffset), Float(sample.positiveOffset), Float(sample.displacement), Float(sample.blueDirection)),
            settings: SIMD4(Float(effect.amount / 100), Float(effect.edgeStrength / 100), sample.hasEdge ? 1 : 0, sample.hasChromatic ? 1 : 0),
            edgeColor: SIMD4(linear(effect.edgeColor.red), linear(effect.edgeColor.green), linear(effect.edgeColor.blue), 0))
        guard image !== output, let encoder = commands.makeComputeCommandEncoder() else { throw MetalSceneRenderer.renderError }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: image.width, height: image.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1))
        encoder.endEncoding()
        return output
    }
}
