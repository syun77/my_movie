import Metal
import CoreImage
import SpineBridge

final class SpineMetalRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var cache: [String: [(MTLTexture, MTLSamplerState)]] = [:]
    private var order: [String] = []
    private var cacheCosts: [String: Int] = [:]

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "spineVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "spineFragment")
        let c = descriptor.colorAttachments[0]!
        c.pixelFormat = .rgba16Float; c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func discardCache() { cache.removeAll(); order.removeAll(); cacheCosts.removeAll() }

    func render(_ packet: SpineDrawPacket, commands: MTLCommandBuffer) throws -> (texture: MTLTexture, reference: CGRect) {
        let bounds = packet.bounds
        let width = Int(bounds.width), height = Int(bounds.height)
        let pages = try textures(packet.pages)
        let cost = width * height * 8 + cacheCosts.values.reduce(0, +)
        guard width > 0, height > 0, width <= 16384, height <= 16384, cost <= 512 * 1024 * 1024 else { throw StudioError.message("Spine GPUメモリの上限を超えています。") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw StudioError.message("Spineの描画面を作成できません。") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw StudioError.message("Spineを描画できません。") }
        encoder.setRenderPipelineState(pipeline)
        // Match the source texture orientation consumed by positionedImage.
        var viewport = SIMD4<Float>(Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 1)
        if !packet.vertices.isEmpty, !packet.indices.isEmpty {
            let vertices = packet.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            let indices = packet.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            guard let vertices, let indices else { encoder.endEncoding(); throw StudioError.message("Spine頂点メモリを確保できません。") }
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            for draw in packet.commands {
                let page = Int(draw.page)
                guard pages.indices.contains(page), Int(draw.start) + Int(draw.count) <= packet.indices.count else { encoder.endEncoding(); throw StudioError.message("Spine描画コマンドが不正です。") }
                encoder.setFragmentTexture(pages[page].0, index: 0)
                encoder.setFragmentSamplerState(pages[page].1, index: 0)
                var pma: UInt32 = packet.pages.pages[page].pma ? 1 : 0
                encoder.setFragmentBytes(&pma, length: 4, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: Int(draw.count), indexType: .uint32, indexBuffer: indices, indexBufferOffset: Int(draw.start) * 4)
            }
        }
        encoder.endEncoding()
        commands.addCompletedHandler { _ in _ = packet; _ = pages }
        return (texture, CGRect(x: packet.referenceBounds.minX - bounds.minX, y: bounds.maxY - packet.referenceBounds.maxY, width: packet.referenceBounds.width, height: packet.referenceBounds.height))
    }

    static func thumbnail(_ packet: SpineDrawPacket, maximumSize: Int) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer() else { throw StudioError.message("SpineにMetalが必要です。") }
        let renderer = try SpineMetalRenderer(device: device, library: SceneShaders.library(device: device))
        let result = try renderer.render(packet, commands: commands)
        commands.commit(); commands.waitUntilCompleted()
        guard commands.status == .completed,
              let image = CIImage(mtlTexture: result.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]) else { throw StudioError.message("Spineの静止表示に失敗しました。") }
        let upright = image
        let fit = min(1, CGFloat(maximumSize) / max(upright.extent.width, upright.extent.height))
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        let context = CIContext(mtlDevice: device)
        guard let output = context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw StudioError.message("Spineのサムネイルを作成できません。") }
        return output
    }

    private func textures(_ source: SpinePages) throws -> [(MTLTexture, MTLSamplerState)] {
        let key = source.revision
        if let value = cache[key] { order.removeAll { $0 == key }; order.append(key); return value }
        let cost = source.pages.reduce(0) { $0 + $1.bytes.count }
        while cacheCosts.values.reduce(cost, +) > 256 * 1024 * 1024 || cache.count >= 16 {
            guard let old = order.first else { throw StudioError.message("Spine atlasのGPU予算を超えています。") }
            order.removeFirst(); cache[old] = nil; cacheCosts[old] = nil
        }
        let values = try source.pages.map { page -> (MTLTexture, MTLSamplerState) in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: page.width, height: page.height, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw StudioError.message("Spine atlasをGPUへ読み込めません。") }
            page.bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, page.width, page.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: page.width * 4) }
            let sampler = MTLSamplerDescriptor()
            sampler.minFilter = page.minFilter == 1 ? .nearest : .linear
            sampler.magFilter = page.magFilter == 1 ? .nearest : .linear
            func wrap(_ value: Int32) -> MTLSamplerAddressMode { value == 0 ? .mirrorRepeat : value == 2 ? .repeat : .clampToEdge }
            sampler.sAddressMode = wrap(page.uWrap); sampler.tAddressMode = wrap(page.vWrap)
            guard let state = device.makeSamplerState(descriptor: sampler) else { throw StudioError.message("Spine samplerを作成できません。") }
            return (texture, state)
        }
        cache[key] = values; cacheCosts[key] = cost; order.append(key); return values
    }
}
