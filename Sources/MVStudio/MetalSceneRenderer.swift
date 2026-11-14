import AppKit
import CoreImage
import Metal

final class MetalSceneRenderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let videoSize = CGSize(width: VideoExporter.width, height: VideoExporter.height)
    private let scale: Double
    private let size: CGSize
    private let canvas: CGRect
    private static let cacheLimit = 128 * 1024 * 1024
    private static let filterCacheCleanupInterval = 120
    private typealias OverlayTarget = (texture: MTLTexture, context: CGContext)

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let filters: CIContext
    private let highlight: MTLComputePipelineState
    private let placementPipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let maskedClipPipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let emberPipeline: MTLRenderPipelineState
    private let snowPipeline: MTLRenderPipelineState
    private let orbPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let outputPipeline: MTLRenderPipelineState
    private let spineRenderer: SpineMetalRenderer
    private let scene: MTLTexture

    private struct ImageKey: Equatable {
        let source: VisualFrame
        let transform: CGAffineTransform
        let shape: ImageEffects.Shape?
        let background: RGBColor?
        let correction: ImageEffects.ColorCorrection?
        let blur: Double
        let threshold: Double
        let glowRadius: Double

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source == rhs.source && lhs.transform == rhs.transform && lhs.blur == rhs.blur
                && lhs.shape == rhs.shape && lhs.background == rhs.background && lhs.correction == rhs.correction && lhs.threshold == rhs.threshold && lhs.glowRadius == rhs.glowRadius
        }
    }

    private struct ProcessedImage {
        let key: ImageKey
        let image: MTLTexture
        let glow: MTLTexture?
        var cost: Int { image.width * image.height * 8 * (glow == nil ? 1 : 2) }
    }

    private struct SourceImage {
        let image: VisualFrame
        let texture: MTLTexture
    }

    private struct Placement {
        let origin: SIMD2<Float>
        let horizontal: SIMD2<Float>
        let vertical: SIMD2<Float>
        let targetSize: SIMD2<Float>
    }

    private struct Overlay {
        let texture: MTLTexture
        let bounds: CGRect
    }

    private var framesSinceCleanup = 0
    private var sourceCache: [UUID: SourceImage] = [:]
    private var imageCache: [UUID: ProcessedImage] = [:]
    private var spectrumTarget: OverlayTarget?
    private var maskTargets: [Int: MTLTexture] = [:]
    private var transformScratch: MTLTexture?
    private var bloomScratch: MTLTexture?
    private var lyricsCache: (text: String, style: LyricsStyle, image: Overlay)?

    init(scale: Double = 1) throws {
        self.scale = scale
        size = CGSize(width: Self.videoSize.width * scale, height: Self.videoSize.height * scale)
        canvas = CGRect(origin: .zero, size: size)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw StudioError.message("Metal対応の描画デバイスを利用できません。")
        }
        self.device = device
        self.queue = queue
        filters = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: Self.linearRGB, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false
        ])
        let library = try SceneShaders.library(device: device)
        guard let bloomFunction = library.makeFunction(name: "bloomHighlights") else { throw Self.renderError }
        highlight = try device.makeComputePipelineState(function: bloomFunction)
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = .rgba16Float,
                      blending: Bool = true, additive: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format
            color.isBlendingEnabled = blending
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = additive ? .zero : .one
            color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        placementPipeline = try pipeline("positionedImage", "sourceImage", blending: true)
        shapePipeline = try pipeline("fullscreen", "coloredShape")
        maskedClipPipeline = try pipeline("fullscreen", "maskedClip")
        guidePipeline = try pipeline("fullscreen", "maskGuide")
        imagePipeline = try pipeline("fullscreen", "imageLayer")
        particlePipeline = try pipeline("particleQuad", "particleLight", additive: true)
        emberPipeline = try pipeline("particleQuad", "emberLight", additive: true)
        snowPipeline = try pipeline("particleQuad", "snowFlake")
        orbPipeline = try pipeline("particleQuad", "orbLight", additive: true)
        overlayPipeline = try pipeline("fullscreen", "artwork")
        outputPipeline = try pipeline("fullscreen", "outputColor", format: .bgra8Unorm, blending: false)
        spineRenderer = try SpineMetalRenderer(device: device, library: library)
        scene = try Self.makeTexture(device: device, width: Int(size.width), height: Int(size.height),
                                     format: .rgba16Float, usage: [.shaderRead, .renderTarget])
    }

    // The caller keeps one frame in flight per renderer.
    func encode(visuals: [VisualRenderLayer], features: AudioFeatures?, settings: SceneSettings, lyrics: LyricsTrack,
                time: Double, target: MTLTexture, video: Bool, guideClipID: UUID? = nil) throws -> MTLCommandBuffer {
        if framesSinceCleanup == Self.filterCacheCleanupInterval {
            filters.clearCaches()
            framesSinceCleanup = 0
        }
        framesSinceCleanup += 1
        guard let commands = queue.makeCommandBuffer() else { throw Self.renderError }
        var prepared: [(clip: VisualClip, image: ProcessedImage, intensity: Float, slot: Int)] = []
        var nextSources: [UUID: SourceImage] = [:]
        var nextCache: [UUID: ProcessedImage] = [:]
        var cost = 0
        for layer in visuals where layer.clip.start <= time && time < layer.clip.end {
            let frame: VisualFrame
            switch layer.source {
            case let .frame(value): frame = value
            case let .spine(packet):
                let rendered = try spineRenderer.render(packet, commands: commands)
                frame = try VisualFrame(texture: rendered.texture, referenceBounds: rendered.reference)
            }
            var clip = layer.clip
            clip.effects = clip.evaluatedEffects(at: time, settings: settings, features: features)
            let blur = clip.effects?.blur
            let bloom = clip.effects?.bloom
            let glows = bloom.map { $0.isEnabled && $0.intensity > 0 && $0.threshold < 100 } ?? false
            let key = ImageKey(source: frame, transform: transform(frame, clip: layer.clip, at: time, settings: settings, features: features, shake: clip.effects?.shake),
                               shape: clip.effects?.shape.flatMap { $0.isEnabled ? $0 : nil },
                               background: clip.effects?.solidBackground.flatMap { $0.isEnabled ? $0.color : nil },
                               correction: clip.effects?.colorCorrection.flatMap { $0.isEnabled ? $0 : nil },
                               blur: blur?.isEnabled == true ? blur?.radius ?? 0 : 0,
                               threshold: glows ? (bloom?.threshold ?? 0) / 100 : 0,
                               glowRadius: glows ? bloom?.radius ?? 0 : 0)
            let sourceID = clip.assetID ?? clip.id
            let source = try sourceTexture(frame, cached: nextSources[sourceID] ?? sourceCache[sourceID], commands: commands)
            nextSources[sourceID] = source
            let previous = imageCache[clip.id]
            let image = try (previous?.key == key ? previous : nil)
                ?? process(key, source: source.texture, reusing: previous, commands: commands)
            prepared.append((clip, image, glows ? Float((bloom?.intensity ?? 0) / 100) : 0, layer.slot))
            if cost + image.cost <= Self.cacheLimit {
                nextCache[clip.id] = image
                cost += image.cost
            }
        }
        let overlays = try foreground(features: features, settings: settings, lyrics: lyrics, time: time)

        let clear = MTLClearColor(red: Self.linear(0.025), green: Self.linear(0.035), blue: Self.linear(0.065), alpha: 1)
        var composition = try encoder(commands, target: scene, clear: clear)
        var intermediates: [Int: MTLTexture] = [:]
        for item in prepared.sorted(by: { $0.slot < $1.slot }) {
            let (clip, layer, intensity, slot) = item
            let maskOwner = prepared.first { $0.slot == slot + 1 && $0.clip.effects?.mask?.isEnabled == true && $0.clip.effects?.mask?.target == .below }
            var intermediate: MTLTexture?
            if maskOwner != nil {
                composition.endEncoding()
                let texture = try filterTexture(bounds: canvas, reusing: maskTargets[slot])
                intermediate = texture
                intermediates[slot] = texture
                composition = try encoder(commands, target: texture, clear: MTLClearColorMake(0, 0, 0, 0))
            }
            drawClip(clip, image: layer, intensity: intensity, at: time, settings: settings, features: features, encoder: composition)
            if let intermediate, let maskOwner {
                composition.endEncoding()
                composition = try encoder(commands, target: scene, clear: clear, load: true)
                let ownerOpacity = ParameterEvaluator.value(.opacity, clip: maskOwner.clip, at: time, settings: settings, features: features) / 100
                var mask = ShapeRenderer.mask(maskOwner.clip.effects?.mask, opacity: ownerOpacity)
                composition.setRenderPipelineState(maskedClipPipeline)
                composition.setFragmentTexture(intermediate, index: 0)
                composition.setFragmentBytes(&mask, length: MemoryLayout<ShapeRenderer.Uniforms>.stride, index: 0)
                quad(composition)
            }
        }
        if !video, let guide = prepared.first(where: { $0.clip.id == guideClipID }), let mask = guide.clip.effects?.mask, mask.isEnabled {
            var uniforms = ShapeRenderer.uniforms(mask.geometry)
            composition.setRenderPipelineState(guidePipeline)
            composition.setFragmentBytes(&uniforms, length: MemoryLayout<ShapeRenderer.Uniforms>.stride, index: 0)
            quad(composition)
        }
        composition.setRenderPipelineState(overlayPipeline)
        for overlay in overlays {
            composition.setViewport(MTLViewport(originX: overlay.bounds.minX, originY: size.height - overlay.bounds.maxY,
                                                width: overlay.bounds.width, height: overlay.bounds.height, znear: 0, zfar: 1))
            composition.setFragmentTexture(overlay.texture, index: 0)
            quad(composition)
        }
        composition.endEncoding()

        let output = try encoder(commands, target: target, clear: MTLClearColorMake(0, 0, 0, 1))
        let fit = min(Double(target.width) / size.width, Double(target.height) / size.height)
        let width = size.width * fit
        let height = size.height * fit
        output.setViewport(MTLViewport(originX: (Double(target.width) - width) / 2, originY: (Double(target.height) - height) / 2,
                                       width: width, height: height, znear: 0, zfar: 1))
        output.setRenderPipelineState(outputPipeline)
        output.setFragmentTexture(scene, index: 0)
        var transfer: UInt32 = video ? 1 : 0
        output.setFragmentBytes(&transfer, length: MemoryLayout<UInt32>.size, index: 0)
        quad(output)
        output.endEncoding()
        commands.addCompletedHandler { [intermediates] _ in _ = visuals; _ = intermediates }
        sourceCache = nextSources
        maskTargets = intermediates
        imageCache = nextCache
        return commands
    }

    private func drawClip(_ clip: VisualClip, image: ProcessedImage, intensity: Float, at time: Double,
                          settings: SceneSettings, features: AudioFeatures?, encoder: MTLRenderCommandEncoder) {
        let spriteSize = SIMD2<Double>(Self.videoSize.width, Self.videoSize.height)
        let opacity = Float(min(100, max(0, ParameterEvaluator.value(.opacity, clip: clip, at: time, settings: settings, features: features))) / 100)
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setFragmentTexture(image.image, index: 0)
        encoder.setFragmentTexture(image.glow ?? image.image, index: 1)
        var values = SIMD4(Float(scene.width) / Float(image.image.width), Float(scene.height) / Float(image.image.height), intensity, opacity)
        encoder.setFragmentBytes(&values, length: MemoryLayout.size(ofValue: values), index: 0)
        var ownMask = ShapeRenderer.mask(clip.effects?.mask.flatMap { $0.target == .image ? $0 : nil })
        encoder.setFragmentBytes(&ownMask, length: MemoryLayout<ShapeRenderer.Uniforms>.stride, index: 1)
        quad(encoder)
        let localTime = time - clip.start
        if let particles = clip.effects?.particles, particles.isEnabled, particles.opacity > 0 {
            let time = localTime + particles.phaseOffset
            let huePhase = (time / 20).truncatingRemainder(dividingBy: 1)
            var palette = SIMD4(Float(particles.color.red), Float(particles.color.green), Float(particles.color.blue), Float(huePhase))
            encoder.setFragmentBytes(&palette, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            for emitter in particles.emitters {
                drawSprites(particles.instances(at: localTime, size: spriteSize, emitter: emitter),
                            with: particlePipeline, encoder: encoder, opacity: opacity)
            }
        }
        if let embers = clip.effects?.embers, embers.isEnabled, embers.brightness > 0 {
            drawSprites(embers.instances(at: localTime, size: spriteSize), with: emberPipeline, encoder: encoder, opacity: opacity)
        }
        if let snow = clip.effects?.snow, snow.isEnabled, snow.opacity > 0 {
            drawSprites(snow.instances(at: localTime, size: spriteSize), with: snowPipeline, encoder: encoder, opacity: opacity)
        }
        if let orbs = clip.effects?.orbs, orbs.isEnabled, orbs.opacity > 0 {
            ImageEffects.Orbs.colors.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            var saturation = Float(orbs.saturation / 100)
            encoder.setFragmentBytes(&saturation, length: MemoryLayout<Float>.size, index: 1)
            drawSprites(orbs.instances(at: localTime, size: spriteSize), with: orbPipeline, encoder: encoder, opacity: opacity)
        }
    }

    func discardCache() {
        spineRenderer.discardCache()
        maskTargets.removeAll()
        sourceCache.removeAll()
        imageCache.removeAll()
        lyricsCache = nil
        spectrumTarget = nil
        bloomScratch = nil
        transformScratch = nil
    }

    private func transform(_ image: VisualFrame, clip: VisualClip, at time: Double, settings: SceneSettings, features: AudioFeatures?, shake: ImageEffects.Shake?) -> CGAffineTransform {
        let reference = image.referenceBounds ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let fit = min(size.width / reference.width, size.height / reference.height)
        let imageScale = fit * (ParameterEvaluator.value(.scale, clip: clip, at: time, settings: settings, features: features) / 100)
        let displacement = shake?.displacement(at: time - clip.start) ?? .zero
        let angle = ParameterEvaluator.value(.rotation, clip: clip, at: time, settings: settings, features: features).truncatingRemainder(dividingBy: 360) * (-.pi / 180)
        return CGAffineTransform(translationX: size.width / 2 + (ParameterEvaluator.value(.x, clip: clip, at: time, settings: settings, features: features) + displacement.x) * scale,
                                 y: size.height / 2 + (ParameterEvaluator.value(.y, clip: clip, at: time, settings: settings, features: features) + displacement.y) * scale)
            .rotated(by: angle).scaledBy(x: imageScale, y: imageScale)
            .translatedBy(x: -reference.midX, y: -reference.midY)
    }

    private func sourceTexture(_ image: VisualFrame, cached: SourceImage?, commands: MTLCommandBuffer) throws -> SourceImage {
        if let cached, cached.image == image { return cached }
        if let texture = image.texture { return SourceImage(image: image, texture: texture) }
        let source = image.image
        let texture = try render(source, bounds: source.extent, reusing: nil, commands: commands)
        return SourceImage(image: image, texture: texture)
    }

    private func process(_ key: ImageKey, source: MTLTexture, reusing previous: ProcessedImage?, commands: MTLCommandBuffer) throws -> ProcessedImage {
        let padding = key.blur + key.glowRadius > 0 ? ceil(3 * (key.blur + key.glowRadius) * scale) + 2 : 0
        let bounds = CGRect(origin: .zero, size: canvas.insetBy(dx: -padding, dy: -padding).size)
        let positioned = try filterTexture(bounds: bounds, reusing: key.blur > 0 || key.correction != nil ? transformScratch : previous?.image)
        var placement = placement(for: key, padding: padding, bounds: bounds)
        let clear = key.background.map { MTLClearColorMake(Self.linear($0.red), Self.linear($0.green), Self.linear($0.blue), 1) }
            ?? MTLClearColorMake(0, 0, 0, 0)
        let pass = try encoder(commands, target: positioned, clear: clear)
        pass.setRenderPipelineState(placementPipeline)
        pass.setVertexBytes(&placement, length: MemoryLayout<Placement>.stride, index: 0)
        pass.setFragmentTexture(source, index: 0)
        quad(pass)
        if let shape = key.shape {
            var uniforms = ShapeRenderer.uniforms(shape.geometry)
            uniforms.color = SIMD4(Float(Self.linear(shape.color.red)), Float(Self.linear(shape.color.green)), Float(Self.linear(shape.color.blue)), Float(shape.opacity / 100))
            uniforms.viewport = SIMD4(Float(bounds.width), Float(bounds.height), Float(padding), Float(scale))
            pass.setRenderPipelineState(shapePipeline)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<ShapeRenderer.Uniforms>.stride, index: 0)
            quad(pass)
        }
        pass.endEncoding()

        var rendered = positioned
        if key.blur > 0 || key.correction != nil {
            transformScratch = positioned
            guard let input = CIImage(mtlTexture: positioned, options: [.colorSpace: Self.linearRGB]) else { throw Self.renderError }
            var filtered = input
            if let correction = key.correction {
                filtered = filtered.applyingFilter("CIHueAdjust", parameters: ["inputAngle": correction.hue * .pi / 180])
                    .applyingFilter("CIColorControls", parameters: ["inputBrightness": correction.brightness / 100,
                                                                   "inputSaturation": correction.saturation / 100])
            }
            if key.blur > 0 { filtered = filtered.applyingGaussianBlur(sigma: key.blur * scale) }
            rendered = try render(filtered, bounds: bounds,
                                  reusing: previous?.image, commands: commands)
        }
        let glow = key.glowRadius > 0 ? try bloom(rendered, key: key, bounds: bounds, reusing: previous?.glow, commands: commands) : nil
        return ProcessedImage(key: key, image: rendered, glow: glow)
    }

    private func placement(for key: ImageKey, padding: Double, bounds: CGRect) -> Placement {
        let transform = key.transform
        let origin = SIMD2(Float(transform.tx + padding), Float(transform.ty + padding))
        let width = Float(key.source.width)
        let height = Float(key.source.height)
        return Placement(origin: origin, horizontal: SIMD2(Float(transform.a), Float(transform.b)) * width,
                         vertical: SIMD2(Float(transform.c), Float(transform.d)) * height,
                         targetSize: SIMD2(Float(bounds.width), Float(bounds.height)))
    }

    private func bloom(_ image: MTLTexture, key: ImageKey, bounds: CGRect, reusing previous: MTLTexture?, commands: MTLCommandBuffer) throws -> MTLTexture {
        let emission = try filterTexture(bounds: bounds, reusing: bloomScratch)
        bloomScratch = emission
        guard let encoder = commands.makeComputeCommandEncoder() else { throw Self.renderError }
        encoder.setComputePipelineState(highlight)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(emission, index: 1)
        var threshold = Float(key.threshold)
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        let columns = highlight.threadExecutionWidth
        let rows = max(1, highlight.maxTotalThreadsPerThreadgroup / columns)
        encoder.dispatchThreadgroups(MTLSize(width: (image.width + columns - 1) / columns,
                                            height: (image.height + rows - 1) / rows, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: columns, height: rows, depth: 1))
        encoder.endEncoding()
        guard let glow = CIImage(mtlTexture: emission, options: [.colorSpace: Self.linearRGB]) else { throw Self.renderError }
        return try render(glow.applyingGaussianBlur(sigma: key.glowRadius * scale), bounds: bounds, reusing: previous, commands: commands)
    }

    private func filterTexture(bounds: CGRect, reusing previous: MTLTexture?) throws -> MTLTexture {
        let width = Int(bounds.width), height = Int(bounds.height)
        if let previous, previous.width == width, previous.height == height { return previous }
        return try Self.makeTexture(device: device, width: width, height: height,
                                    format: .rgba16Float, usage: [.shaderRead, .shaderWrite, .renderTarget])
    }

    private func render(_ image: CIImage, bounds: CGRect, reusing previous: MTLTexture?, commands: MTLCommandBuffer) throws -> MTLTexture {
        let texture = try filterTexture(bounds: bounds, reusing: previous)
        let cleared = image.composited(over: CIImage(color: .clear).cropped(to: bounds))
        filters.render(cleared, to: texture, commandBuffer: commands, bounds: bounds, colorSpace: Self.linearRGB)
        return texture
    }

    private func drawSprites(_ instances: [SIMD4<Float>], with pipeline: MTLRenderPipelineState, encoder: MTLRenderCommandEncoder, opacity: Float) {
        let instances = opacity == 1 ? instances : instances.map { SIMD4($0.x, $0.y, $0.z, $0.w * opacity) }
        var size = SIMD2(Float(Self.videoSize.width), Float(Self.videoSize.height))
        encoder.setRenderPipelineState(pipeline)
        instances.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setVertexBytes(&size, length: MemoryLayout.size(ofValue: size), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }

    private func foreground(features: AudioFeatures?, settings: SceneSettings, lyrics: LyricsTrack, time: Double) throws -> [Overlay] {
        var overlays: [Overlay] = []
        if settings.spectrum, let features {
            let bounds = settings.spectrumStyle.layout.bounds(in: size).insetBy(dx: -3, dy: -3).integral.intersection(canvas)
            if !bounds.isEmpty {
                let target: OverlayTarget
                if let previous = spectrumTarget, previous.texture.width == Int(bounds.width), previous.texture.height == Int(bounds.height) {
                    target = previous
                } else {
                    target = try overlayTarget(size: bounds.size)
                    spectrumTarget = target
                }
                overlays.append(try overlay(bounds: bounds, target: target) { context in
                    SpectrumRenderer.draw(in: context, size: size, features: features, time: time, style: settings.spectrumStyle)
                })
            }
        } else {
            spectrumTarget = nil
        }
        if let text = lyrics.text(at: time), !text.isEmpty {
            let style = lyrics.style
            if lyricsCache?.text != text || lyricsCache?.style != style {
                let image = try overlay(bounds: canvas, target: overlayTarget(size: size)) { context in
                    LyricsRenderer.draw(in: context, size: size, track: lyrics, time: time)
                }
                lyricsCache = (text, style, image)
            }
            if let image = lyricsCache?.image { overlays.append(image) }
        } else {
            lyricsCache = nil
        }
        return overlays
    }

    private func overlayTarget(size: CGSize) throws -> OverlayTarget {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: Self.sRGB, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw Self.renderError
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Self.renderError }
        return (texture, context)
    }

    private func overlay(bounds: CGRect, target: OverlayTarget, draw: (CGContext) -> Void) throws -> Overlay {
        let (texture, context) = target
        guard let pixels = context.data else { throw Self.renderError }
        context.clear(CGRect(origin: .zero, size: bounds.size))
        context.saveGState()
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(context)
        context.restoreGState()
        texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: context.bytesPerRow)
        return Overlay(texture: texture, bounds: bounds)
    }

    private func encoder(_ commands: MTLCommandBuffer, target: MTLTexture, clear: MTLClearColor, load: Bool = false) throws -> MTLRenderCommandEncoder {
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = target
        color.loadAction = load ? .load : .clear
        color.storeAction = .store
        color.clearColor = clear
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw Self.renderError }
        return encoder
    }

    private func quad(_ encoder: MTLRenderCommandEncoder) {
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat,
                                    usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw renderError }
        return texture
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static var renderError: StudioError { .message("Metalでフレームを描画できません。") }
}
