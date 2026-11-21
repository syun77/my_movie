import Metal
import Foundation

/// Places a generated background behind the current premultiplied chain surface.
final class GradientBackgroundRenderer {
    private let pipeline: MTLRenderPipelineState
    struct Uniforms {
        var viewport: SIMD4<Float>
        var geometry: SIMD4<Float>
        var profile: SIMD4<Float>
        var colorA: SIMD4<Float>
        var colorB: SIMD4<Float>
    }
    init(device: MTLDevice, library: MTLLibrary) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "gradientBackground")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
        attachment.destinationAlphaBlendFactor = .one
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    func render(into target: MTLTexture, effect: ImageEffects.GradientBackground, scale: Double,
                padding: Double, commands: MTLCommandBuffer) throws {
        guard effect.isEnabled && effect.opacity > 0 else { return }
        func linear(_ v: Double) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
        func rgb(_ color: RGBColor) -> SIMD4<Float> { SIMD4(linear(color.red), linear(color.green), linear(color.blue), 0) }
        var uniforms = Uniforms(
            viewport: SIMD4(Float(target.width), Float(target.height), Float(padding), Float(scale)),
            geometry: SIMD4(Float(effect.x), Float(effect.y), Float(effect.position), Float(effect.width)),
            profile: SIMD4(Float(effect.angle * .pi / 180), Float(pow(2, 4 * effect.bias / 100)),
                           effect.shape == .radial ? 1 : 0, effect.pattern == .mirrored ? 1 : 0),
            colorA: rgb(effect.colorA), colorB: rgb(effect.colorB))
        uniforms.colorA.w = Float(effect.opacity / 100)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let pass = commands.makeRenderCommandEncoder(descriptor: descriptor) else { throw MetalSceneRenderer.renderError }
        pass.setRenderPipelineState(pipeline)
        pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        pass.endEncoding()
    }
}
