import Metal
import Foundation

/// Generates two independent directional light fields in linear premultiplied RGBA.
final class CrossGlareRenderer {
    private let device: MTLDevice
    private let highlight: MTLComputePipelineState
    private let spread: MTLComputePipelineState
    private let merge: MTLComputePipelineState
    private var scratch: [MTLTexture] = []

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw MetalSceneRenderer.renderError }
            return try device.makeComputePipelineState(function: function)
        }
        highlight = try pipeline("bloomHighlights")
        spread = try pipeline("glareSpread")
        merge = try pipeline("glareMerge")
    }

    /// The sum of the tap offsets is the finite support radius. Each stage preserves energy.
    static func steps(radius: Double) -> [Double] {
        guard radius > 0 else { return [] }
        var remaining = radius
        var step = 1.0
        var result: [Double] = []
        while remaining > 0.000001 {
            let value = min(step, remaining)
            result.append(value)
            remaining -= value
            step *= 2
        }
        return result
    }

    func discardCache() { scratch.removeAll() }

    func render(_ image: MTLTexture, effect: ImageEffects.CrossGlare, scale: Double,
                reusing previous: MTLTexture?, commands: MTLCommandBuffer) throws -> MTLTexture {
        func texture() throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: image.width, height: image.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let result = device.makeTexture(descriptor: descriptor) else { throw MetalSceneRenderer.renderError }
            return result
        }
        if scratch.first?.width != image.width || scratch.first?.height != image.height {
            scratch = try (0..<4).map { _ in try texture() }
        }
        let output: MTLTexture
        if let previous, previous.width == image.width, previous.height == image.height { output = previous }
        else { output = try texture() }
        guard let encoder = commands.makeComputeCommandEncoder() else { throw MetalSceneRenderer.renderError }
        func run(_ pipeline: MTLComputePipelineState, _ textures: [MTLTexture]) {
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            let width = pipeline.threadExecutionWidth
            let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
            encoder.dispatchThreads(MTLSize(width: image.width, height: image.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        }
        var threshold = Float(effect.threshold / 100)
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        run(highlight, [image, scratch[0]])
        for axis in 0..<2 {
            // CI-backed textures have their vertical axis reversed relative to screen coordinates.
            let angle = -(effect.angle + Double(axis) * 90) * .pi / 180
            let direction = SIMD2(Float(cos(angle)), Float(sin(angle)))
            var source = scratch[0]
            var targetIndex = 1
            let stages = Self.steps(radius: effect.length * scale).map { direction * Float($0) }
                + Self.steps(radius: max(0, effect.width * scale / 2)).map { SIMD2(-direction.y, direction.x) * Float($0) }
            for var offset in stages {
                let target = scratch[targetIndex]
                encoder.setBytes(&offset, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                run(spread, [source, target])
                source = target
                targetIndex = targetIndex == 1 ? 2 : 1
            }
            if axis == 0 {
                // Preserve the first axis while the second starts again from the extraction.
                var zero = SIMD2<Float>.zero
                encoder.setBytes(&zero, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                run(spread, [source, scratch[3]])
            } else { run(merge, [scratch[3], source, output]) }
        }
        encoder.endEncoding()
        return output
    }
}
