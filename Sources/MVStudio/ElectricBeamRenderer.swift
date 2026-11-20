import Metal
import Foundation

/// Unions each path in one reusable surface, then adds its emission without changing coverage.
final class ElectricBeamRenderer {
    private let device: MTLDevice
    private let unionPipeline: MTLRenderPipelineState
    private let addPipeline: MTLRenderPipelineState
    private var surface: MTLTexture?
    private struct Path {
        let buffer: MTLBuffer
        let count: Int
    }
    private var geometryCache: [(ElectricBeamGeometry.Key, [Path])] = []

    struct Uniforms {
        var viewport: SIMD4<Float>
        var color: SIMD4<Float>
        var light: SIMD4<Float>
    }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(union: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: union ? "electricBeamQuad" : "fullscreen")
            descriptor.fragmentFunction = library.makeFunction(name: union ? "electricBeamLight" : "chainCopy")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .rgba16Float; color.isBlendingEnabled = true
            color.rgbBlendOperation = union ? .max : .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .zero; color.destinationAlphaBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        unionPipeline = try pipeline(union: true); addPipeline = try pipeline(union: false)
    }

    func render(into target: MTLTexture, effect: ImageEffects.ElectricBeam, localTime: Double,
                scale: Double, padding: Double, commands: MTLCommandBuffer) throws {
        guard effect.isEnabled && effect.brightness > 0 else { return }
        let key = ElectricBeamGeometry.Key(effect, at: localTime)
        let paths: [Path]
        if let cached = geometryCache.first(where: { $0.0 == key }) { paths = cached.1 }
        else {
            paths = try ElectricBeamGeometry.paths(key).filter { !$0.isEmpty }.map { segments in
                guard let buffer = segments.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else {
                    throw MetalSceneRenderer.renderError
                }
                return Path(buffer: buffer, count: segments.count)
            }
            geometryCache.append((key, paths))
            if geometryCache.count > VisualTrack.maximumLayers { geometryCache.removeFirst() }
        }
        if surface?.width != target.width || surface?.height != target.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: target.width, height: target.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
            surface = device.makeTexture(descriptor: descriptor)
        }
        guard let surface else { throw MetalSceneRenderer.renderError }
        func linear(_ v: Double) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
        var uniforms = Uniforms(viewport: SIMD4(Float(target.width), Float(target.height), Float(padding), Float(scale)),
                                color: SIMD4(linear(effect.color.red), linear(effect.color.green), linear(effect.color.blue), 0),
                                light: SIMD4(Float(effect.glowRadius), Float(effect.brightness / 100), 0, 0))
        for path in paths {
            let pass = try encoder(commands, target: surface, clear: true)
            pass.setRenderPipelineState(unionPipeline)
            pass.setVertexBuffer(path.buffer, offset: 0, index: 0)
            pass.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: path.count)
            pass.endEncoding()
            let add = try encoder(commands, target: target, clear: false)
            add.setRenderPipelineState(addPipeline); add.setFragmentTexture(surface, index: 0)
            var settings = SIMD2<Float>(1, 0)
            add.setFragmentBytes(&settings, length: MemoryLayout.size(ofValue: settings), index: 0)
            add.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); add.endEncoding()
        }
    }

    private func encoder(_ commands: MTLCommandBuffer, target: MTLTexture, clear: Bool) throws -> MTLRenderCommandEncoder {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { throw MetalSceneRenderer.renderError }
        return encoder
    }
}
