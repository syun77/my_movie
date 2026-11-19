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
    private let sobelChromaticRenderer: SobelChromaticRenderer
    private let radialBlurRenderer: RadialBlurRenderer
    private let crossGlareRenderer: CrossGlareRenderer
    private let chainEmissionPipeline: MTLRenderPipelineState
    private let chainCopyPipeline: MTLRenderPipelineState
    private let chainMaskPipeline: MTLRenderPipelineState
    private let chainLoopPipeline: MTLRenderPipelineState
    private let highlight: MTLComputePipelineState
    private let placementPipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let maskedClipPipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let particleImagePipeline: MTLRenderPipelineState
    private let particleImageAddPipeline: MTLRenderPipelineState
    private var particleTextureCache: [UUID: SourceImage] = [:]
    private let particlePipeline: MTLRenderPipelineState
    private let emberPipeline: MTLRenderPipelineState
    private let snowPipeline: MTLRenderPipelineState
    private let octPipeline: MTLRenderPipelineState
    private let warpPipeline: MTLRenderPipelineState
    private let lensFlarePipeline: MTLRenderPipelineState
    private let radialFocusPipeline: MTLRenderPipelineState
    private let raysPipeline: MTLRenderPipelineState
    private let straightPipeline: MTLRenderPipelineState
    private let straightGlowPipeline: MTLRenderPipelineState
    private let sharpPipeline: MTLRenderPipelineState
    private let focusPipeline: MTLRenderPipelineState
    private let orbPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let outputPipeline: MTLRenderPipelineState
    private let spineRenderer: SpineMetalRenderer
    private let scene: MTLTexture

    private struct ImageKey: Equatable {
        let source: VisualFrame
        var particleImages: [UUID: VisualFrame] = [:]
        let transform: CGAffineTransform
        let chain: ImageEffects
        let localTime: Double
    }
    private struct ProcessedImage {
        let key: ImageKey
        let image: MTLTexture
        var cost: Int { image.width * image.height * 8 }
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
    private var maskTargets: [UUID: MTLTexture] = [:]
    private var chainScratch: [MTLTexture] = []
    private var generatorScratch: MTLTexture?
    private var glowScratch: MTLTexture?
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
        sobelChromaticRenderer = try SobelChromaticRenderer(device: device, library: library)
        radialBlurRenderer = try RadialBlurRenderer(device: device, library: library)
        crossGlareRenderer = try CrossGlareRenderer(device: device, library: library)
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
        chainEmissionPipeline = try pipeline("fullscreen", "chainCopy", additive: true)
        chainCopyPipeline = try pipeline("fullscreen", "chainCopy")
        chainMaskPipeline = try pipeline("fullscreen", "chainMask", blending: false)
        chainLoopPipeline = try pipeline("fullscreen", "chainLoop", blending: false)
        placementPipeline = try pipeline("positionedImage", "sourceImage", blending: true)
        shapePipeline = try pipeline("fullscreen", "coloredShape")
        maskedClipPipeline = try pipeline("fullscreen", "maskedClip")
        guidePipeline = try pipeline("fullscreen", "maskGuide")
        imagePipeline = try pipeline("fullscreen", "imageLayer")
        particleImagePipeline = try pipeline("imageParticleQuad", "imageParticle")
        particleImageAddPipeline = try pipeline("imageParticleQuad", "imageParticle", additive: true)
        particlePipeline = try pipeline("particleQuad", "particleLight", additive: true)
        emberPipeline = try pipeline("particleQuad", "emberLight", additive: true)
        snowPipeline = try pipeline("particleQuad", "snowFlake")
        octPipeline = try pipeline("fullscreen", "octgrams")
        warpPipeline = try pipeline("fullscreen", "warpFlight")
        lensFlarePipeline = try pipeline("fullscreen", "lensFlare", additive: true)
        radialFocusPipeline = try pipeline("fullscreen", "radialFocus", additive: true)
        raysPipeline = try pipeline("raysQuad", "raysLight", additive: true)
        straightPipeline = try pipeline("straightQuad", "straightInk")
        straightGlowPipeline = try pipeline("straightQuad", "straightGlow", additive: true)
        sharpPipeline = try pipeline("sharpQuad", "sharpInk")
        focusPipeline = try pipeline("focusQuad", "focusInk")
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
        var usedParticleTextures = Set<UUID>()
        var prepared: [(clip: VisualClip, image: ProcessedImage, layerID: UUID, order: Int, maskOwnerID: UUID?)] = []
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
            let chain = clip.effects ?? ImageEffects()
            let key = ImageKey(source: frame, particleImages: layer.particleImages,
                               transform: transform(frame, clip: layer.clip, at: time, settings: settings, features: features),
                               chain: chain, localTime: chain.needsClock ? time - clip.start : 0)
            let sourceID = clip.assetID ?? clip.id
            let source = try sourceTexture(frame, cached: nextSources[sourceID] ?? sourceCache[sourceID], commands: commands)
            nextSources[sourceID] = source
            for (id, frame) in layer.particleImages {
                particleTextureCache[id] = try sourceTexture(frame, cached: particleTextureCache[id], commands: commands)
                usedParticleTextures.insert(id)
            }
            let previous = imageCache[clip.id]
            let image = try (previous?.key == key ? previous : nil)
                ?? process(key, source: source.texture, reusing: previous, commands: commands)
            prepared.append((clip, image, layer.layerID, layer.order, layer.maskOwnerID))
            if cost + image.cost <= Self.cacheLimit {
                nextCache[clip.id] = image
                cost += image.cost
            }
        }
        particleTextureCache = particleTextureCache.filter { usedParticleTextures.contains($0.key) }
        let overlays = try foreground(features: features, settings: settings, lyrics: lyrics, time: time)

        let clear = MTLClearColor(red: Self.linear(0.025), green: Self.linear(0.035), blue: Self.linear(0.065), alpha: 1)
        var composition = try encoder(commands, target: scene, clear: clear)
        var intermediates: [UUID: MTLTexture] = [:]
        for item in prepared.sorted(by: { $0.order < $1.order }) {
            let (clip, layer, layerID, _, maskOwnerID) = item
            let maskOwner = prepared.first { $0.layerID == maskOwnerID && $0.clip.effects?.belowMask?.isEnabled == true }
            var intermediate: MTLTexture?
            if maskOwner != nil {
                composition.endEncoding()
                let texture = try filterTexture(bounds: canvas, reusing: maskTargets[layerID])
                intermediate = texture
                intermediates[layerID] = texture
                composition = try encoder(commands, target: texture, clear: MTLClearColorMake(0, 0, 0, 0))
            }
            try drawClip(clip, image: layer, at: time, settings: settings, features: features, encoder: composition)
            if let intermediate, let maskOwner {
                composition.endEncoding()
                composition = try encoder(commands, target: scene, clear: clear, load: true)
                let ownerOpacity = ParameterEvaluator.value(.opacity, clip: maskOwner.clip, at: time, settings: settings, features: features) / 100
                var mask = ShapeRenderer.mask(maskOwner.clip.effects?.belowMask, opacity: ownerOpacity)
                composition.setRenderPipelineState(maskedClipPipeline)
                composition.setFragmentTexture(intermediate, index: 0)
                composition.setFragmentBytes(&mask, length: MemoryLayout<ShapeRenderer.Uniforms>.stride, index: 0)
                quad(composition)
            }
        }
        if !video, let guide = prepared.first(where: { $0.clip.id == guideClipID }), let mask = (guide.clip.effects?.mask ?? guide.clip.effects?.belowMask), mask.isEnabled {
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

    private func drawClip(_ clip: VisualClip, image: ProcessedImage, at time: Double,
                          settings: SceneSettings, features: AudioFeatures?, encoder: MTLRenderCommandEncoder) throws {
        let opacity = Float(ParameterEvaluator.value(.opacity, clip: clip, at: time, settings: settings, features: features) / 100)
        var values = SIMD4(Float(scene.width) / Float(image.image.width), Float(scene.height) / Float(image.image.height), 0, opacity)
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setFragmentTexture(image.image, index: 0)
        encoder.setFragmentBytes(&values, length: MemoryLayout.size(ofValue: values), index: 0)
        quad(encoder)
    }

    private func drawGenerated(_ clip: VisualClip, at time: Double, particleImages: [UUID: VisualFrame], encoder: MTLRenderCommandEncoder) throws {
        if let node = clip.effects?.nodes.first, let appearance = node.particleAppearance, appearance.usesImage {
            if let id = appearance.assetID, particleImages[id] != nil, let image = particleTextureCache[id] {
                try drawImageParticles(node, texture: image.texture, at: time - clip.start, encoder: encoder)
            }
            return
        }
        let spriteSize = SIMD2<Double>(Self.videoSize.width, Self.videoSize.height)
        let opacity: Float = 1
        if let flare = clip.effects?.lensFlare, flare.isEnabled, flare.intensity > 0, opacity > 0 {
            encoder.setRenderPipelineState(lensFlarePipeline)
            let position = flare.sourcePosition(at: time - clip.start)
            var values = SIMD4(Float(position.x), Float(position.y), Float(flare.size / 100), Float(flare.intensity / 100) * opacity)
            encoder.setFragmentBytes(&values, length: MemoryLayout.size(ofValue: values), index: 0)
            quad(encoder)
        }
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
        if let oct = clip.effects?.octgrams, oct.isEnabled, oct.opacity > 0, opacity > 0 {
            drawFullscreenEffect(pipeline: octPipeline, time: (localTime + oct.phaseOffset) * oct.speed / 100,
                                 zoom: oct.zoom, brightness: oct.brightness, opacity: Float(oct.opacity / 100) * opacity,
                                 encoder: encoder)
        }
        if let warp = clip.effects?.warpFlight, warp.isEnabled, warp.opacity > 0, opacity > 0 {
            drawFullscreenEffect(pipeline: warpPipeline, time: (localTime + warp.phaseOffset) * warp.speed / 100,
                                 zoom: warp.zoom, brightness: warp.brightness, opacity: Float(warp.opacity / 100) * opacity,
                                 encoder: encoder)
        }
        if let radial = clip.effects?.radialFocus, radial.isEnabled, radial.opacity > 0, radial.brightness > 0, opacity > 0 {
            drawRadialFocus(radial, at: localTime, opacity: opacity, encoder: encoder)
        }
        if let focus = clip.effects?.focusLines, focus.isEnabled, opacity > 0 {
            try drawFocus(focus, at: localTime, opacity: opacity, encoder: encoder)
        }
        if let sharp = clip.effects?.sharpFocus, sharp.isEnabled, opacity > 0 {
            try drawSharp(sharp, at: localTime, opacity: opacity, encoder: encoder)
        }
        if let lines = clip.effects?.straightLines, lines.isEnabled, opacity > 0 {
            try drawStraight(lines, at: localTime, opacity: opacity, encoder: encoder)
        }
        if let rays = clip.effects?.radialRays, rays.isEnabled, opacity > 0 {
            try drawRays(rays, at: localTime, opacity: opacity, encoder: encoder)
        }
    }

    private func drawFullscreenEffect(pipeline: MTLRenderPipelineState, time: Double, zoom: Double,
                                      brightness: Double, opacity: Float, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(pipeline)
        var viewport = SIMD4(Float(size.width), Float(size.height), Float(zoom / 100), 0)
        var values = SIMD4(Float(time.truncatingRemainder(dividingBy: 100000)), Float(brightness / 100), opacity, 0)
        encoder.setFragmentBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 0)
        encoder.setFragmentBytes(&values, length: MemoryLayout.size(ofValue: values), index: 1)
        quad(encoder)
    }

    private func drawRadialFocus(_ radial: ImageEffects.RadialFocus, at time: Double, opacity: Float,
                                 encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(radialFocusPipeline)
        var values = SIMD4(Float(((time + radial.phaseOffset) * radial.speed / 100).truncatingRemainder(dividingBy: 100000)),
                           Float(radial.zoom / 100), Float(radial.brightness / 100), Float(radial.opacity / 100) * opacity)
        encoder.setFragmentBytes(&values, length: MemoryLayout.size(ofValue: values), index: 0)
        quad(encoder)
    }

    private func drawFocus(_ focus: ImageEffects.FocusLines, at time: Double, opacity: Float,
                           encoder: MTLRenderCommandEncoder) throws {
        let lines = focus.lines(at: time)
        guard !lines.isEmpty else { return }
        guard let buffer = device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<ImageEffects.FocusLines.Line>.stride) else {
            throw Self.renderError
        }
        encoder.setRenderPipelineState(focusPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD4(Float(size.width), Float(size.height), Float(scale), 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 1)
        var ink = SIMD4(Float(focus.color.red), Float(focus.color.green), Float(focus.color.blue), Float(focus.opacity / 100) * opacity)
        encoder.setFragmentBytes(&ink, length: MemoryLayout.size(ofValue: ink), index: 0)
        var gap = SIMD4(Float(focus.x), Float(focus.y), Float(focus.width / 2), Float(focus.height / 2))
        encoder.setFragmentBytes(&gap, length: MemoryLayout.size(ofValue: gap), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
    }

    private func drawStraight(_ effect: ImageEffects.StraightLines, at time: Double, opacity: Float,
                              encoder: MTLRenderCommandEncoder) throws {
        let lines = effect.lines(at: time)
        guard !lines.isEmpty else { return }
        guard let buffer = device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<ImageEffects.StraightLines.Line>.stride) else {
            throw Self.renderError
        }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD4(Float(size.width), Float(size.height), Float(scale), 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 1)
        var ink = SIMD4(Float(effect.color.red), Float(effect.color.green), Float(effect.color.blue), Float(effect.opacity / 100) * opacity)
        encoder.setFragmentBytes(&ink, length: MemoryLayout.size(ofValue: ink), index: 0)
        encoder.setRenderPipelineState(straightPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
        if effect.glow > 0 {
            encoder.setRenderPipelineState(straightGlowPipeline)
            var strength = Float(effect.glow / 100)
            encoder.setFragmentBytes(&strength, length: MemoryLayout.size(ofValue: strength), index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
        }
    }

    private func drawRays(_ effect: ImageEffects.RadialRays, at time: Double, opacity: Float,
                          encoder: MTLRenderCommandEncoder) throws {
        let instances = effect.instances(at: time)
        guard !instances.isEmpty else { return }
        guard let buffer = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<ImageEffects.RadialRays.Instance>.stride) else {
            throw Self.renderError
        }
        encoder.setRenderPipelineState(raysPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD4(Float(size.width), Float(size.height), Float(scale), 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 1)
        var ink = SIMD4(Float(effect.color.red), Float(effect.color.green), Float(effect.color.blue),
                        Float(effect.opacity / 100 * effect.intensity / 100) * opacity)
        encoder.setFragmentBytes(&ink, length: MemoryLayout.size(ofValue: ink), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }

    private func drawSharp(_ focus: ImageEffects.SharpFocus, at time: Double, opacity: Float,
                           encoder: MTLRenderCommandEncoder) throws {
        let lines = focus.lines(at: time)
        guard !lines.isEmpty else { return }
        guard let buffer = device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<ImageEffects.SharpFocus.Line>.stride) else {
            throw Self.renderError
        }
        encoder.setRenderPipelineState(sharpPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD4(Float(size.width), Float(size.height), Float(scale), 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout.size(ofValue: viewport), index: 1)
        var ink = SIMD4(Float(focus.color.red), Float(focus.color.green), Float(focus.color.blue), Float(focus.opacity / 100) * opacity)
        encoder.setFragmentBytes(&ink, length: MemoryLayout.size(ofValue: ink), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
    }

    func discardCache() {
        chainScratch.removeAll(); generatorScratch = nil; glowScratch = nil
        spineRenderer.discardCache()
        crossGlareRenderer.discardCache()
        maskTargets.removeAll()
        particleTextureCache.removeAll()
        sourceCache.removeAll()
        imageCache.removeAll()
        lyricsCache = nil
        spectrumTarget = nil
        bloomScratch = nil
    }

    private func transform(_ image: VisualFrame, clip: VisualClip, at time: Double, settings: SceneSettings, features: AudioFeatures?) -> CGAffineTransform {
        let reference = image.referenceBounds ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let fit = min(size.width / reference.width, size.height / reference.height)
        let imageScale = fit * (ParameterEvaluator.value(.scale, clip: clip, at: time, settings: settings, features: features) / 100)
        let angle = ParameterEvaluator.value(.rotation, clip: clip, at: time, settings: settings, features: features).truncatingRemainder(dividingBy: 360) * (-.pi / 180)
        return CGAffineTransform(translationX: size.width / 2 + (ParameterEvaluator.value(.x, clip: clip, at: time, settings: settings, features: features)) * scale,
                                 y: size.height / 2 + (ParameterEvaluator.value(.y, clip: clip, at: time, settings: settings, features: features)) * scale)
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
        let nodes = key.chain.isBypassed ? [] : key.chain.nodes.filter(\.isEnabled)
        let support = nodes.reduce(0.0) { value, node in
            switch node.payload {
            case let .blur(v): return value + 3 * v.radius
            case let .bloom(v): return value + 3 * v.radius
            case let .crossGlare(v): return value + v.length + v.width / 2
            case let .shake(v): return value + max(v.x, v.y) * v.strength / 100
            case let .sobelChromatic(v): return value + (v.amount > 0 ? v.sample(at: key.localTime).support : 0)
            case let .chromaticAberration(v): return value + v.displacement(at: key.localTime)
            default: return value
            }
        }
        // Keep fragment derivative quads aligned when a filter changes the shared surface margin.
        let padding = support > 0 ? ceil((ceil(support * scale) + 2) / 2) * 2 : 0
        let bounds = CGRect(x: 0, y: 0, width: canvas.width + padding * 2, height: canvas.height + padding * 2)
        if chainScratch.count != 2 || chainScratch[0].width != Int(bounds.width) || chainScratch[0].height != Int(bounds.height) {
            chainScratch = try (0..<2).map { _ in try filterTexture(bounds: bounds, reusing: nil) }
        }
        var current = chainScratch[0]
        func next() -> MTLTexture { current === chainScratch[0] ? chainScratch[1] : chainScratch[0] }
        var placement = placement(for: key, padding: padding, bounds: bounds)
        let base = try encoder(commands, target: current, clear: MTLClearColorMake(0, 0, 0, 0))
        base.setRenderPipelineState(placementPipeline)
        base.setVertexBytes(&placement, length: MemoryLayout<Placement>.stride, index: 0)
        base.setFragmentTexture(source, index: 0)
        quad(base); base.endEncoding()
        func image() throws -> CIImage {
            guard let value = CIImage(mtlTexture: current, options: [.colorSpace: Self.linearRGB]) else { throw Self.renderError }
            return value
        }
        for node in nodes {
            var filtered: CIImage?
            switch node.payload {
            case let .colorCorrection(v): filtered = try ChainColorRenderer.apply(v, to: image())
            case let .binarization(v): filtered = try BinarizationRenderer.apply(v, to: image())
            case let .chromaticAberration(v):
                if let sample = ChromaticAberrationRenderer.sample(v, at: key.localTime) {
                    filtered = try ChromaticAberrationRenderer.apply(sample, to: image(), bounds: bounds, scale: scale)
                }
            case let .sobelChromatic(v):
                current = try sobelChromaticRenderer.render(current, effect: v, localTime: key.localTime,
                                                            canvas: canvas.size, padding: padding, output: next(), commands: commands)
            case let .vignette(v): filtered = try VignetteRenderer.apply(v, to: image(), canvas: canvas, padding: padding, scale: scale)
            case let .blur(v): if v.radius > 0 { filtered = try image().applyingGaussianBlur(sigma: v.radius * scale) }
            case let .radialBlur(v):
                if v.strength > 0 { current = try radialBlurRenderer.render(current, effect: v, canvas: canvas.size, padding: padding, reusing: next(), commands: commands) }
            case let .shake(v):
                let offset = v.displacement(at: key.localTime)
                filtered = try image().transformed(by: CGAffineTransform(translationX: offset.x * scale, y: offset.y * scale))
            case let .bloom(v):
                if v.intensity > 0 && v.threshold < 100 {
                    let glow = try bloom(current, threshold: v.threshold / 100, radius: v.radius, bounds: bounds, commands: commands)
                    try merge(glow, into: current, gain: Float(v.intensity / 100), additive: true, commands: commands)
                }
            case let .crossGlare(v):
                if v.isActive {
                    var effect = v; effect.intensity = 100
                    let glow = try crossGlareRenderer.render(current, effect: effect, scale: scale, reusing: glowScratch, commands: commands)
                    glowScratch = glow
                    try merge(glow, into: current, gain: Float(v.intensity / 100), additive: true, commands: commands)
                }
            case let .mask(v):
                let output = next()
                let pass = try encoder(commands, target: output, clear: MTLClearColorMake(0, 0, 0, 0))
                pass.setRenderPipelineState(chainMaskPipeline)
                pass.setFragmentTexture(current, index: 0)
                var mask = ShapeRenderer.mask(v)
                var geometry = SIMD4(Float(bounds.width), Float(bounds.height), Float(padding), Float(scale))
                pass.setFragmentBytes(&mask, length: MemoryLayout.size(ofValue: mask), index: 0)
                pass.setFragmentBytes(&geometry, length: MemoryLayout.size(ofValue: geometry), index: 1)
                quad(pass); pass.endEncoding(); current = output
            case let .zoomLoop(v):
                if v.opacity > 0 {
                    let output = next()
                    let pass = try encoder(commands, target: output, clear: MTLClearColorMake(0, 0, 0, 0))
                    pass.setRenderPipelineState(chainLoopPipeline)
                    pass.setFragmentTexture(current, index: 0)
                    var animation = SIMD4(Float((key.localTime + v.phaseOffset) * v.speed / 100), Float(v.zoom / 100), Float(v.brightness / 100), Float(v.opacity / 100))
                    var geometry = SIMD4(Float(bounds.width), Float(bounds.height), Float(padding), Float(scale))
                    var center = SIMD2(Float(v.centerX / 1920), Float(v.centerY / 1080))
                    pass.setFragmentBytes(&animation, length: MemoryLayout.size(ofValue: animation), index: 0)
                    pass.setFragmentBytes(&geometry, length: MemoryLayout.size(ofValue: geometry), index: 1)
                    pass.setFragmentBytes(&center, length: MemoryLayout.size(ofValue: center), index: 2)
                    quad(pass); pass.endEncoding(); current = output
                }
            case let .solidBackground(v):
                guard let color = CIColor(red: Self.linear(v.color.red), green: Self.linear(v.color.green), blue: Self.linear(v.color.blue), alpha: 1, colorSpace: Self.linearRGB) else { throw Self.renderError }
                let background = CIImage(color: color)
                    .cropped(to: CGRect(x: padding, y: padding, width: canvas.width, height: canvas.height))
                filtered = try image().composited(over: background)
            case let .shape(v):
                let pass = try encoder(commands, target: current, clear: MTLClearColorMake(0, 0, 0, 0), load: true)
                var uniforms = ShapeRenderer.uniforms(v.geometry)
                uniforms.color = SIMD4(Float(Self.linear(v.color.red)), Float(Self.linear(v.color.green)), Float(Self.linear(v.color.blue)), Float(v.opacity / 100))
                uniforms.viewport = SIMD4(Float(bounds.width), Float(bounds.height), Float(padding), Float(scale))
                pass.setRenderPipelineState(shapePipeline)
                pass.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
                quad(pass); pass.endEncoding()
            case .belowMask: break
            default:
                let target = try filterTexture(bounds: canvas, reusing: generatorScratch)
                generatorScratch = target
                let pass = try encoder(commands, target: target, clear: MTLClearColorMake(0, 0, 0, 0))
                var one = ImageEffects(); one.nodes = [node]
                let clip = VisualClip(start: 0, end: .greatestFiniteMagnitude, effects: one)
                try drawGenerated(clip, at: key.localTime, particleImages: key.particleImages, encoder: pass)
                pass.endEncoding()
                try merge(target, into: current, flip: true, padding: padding, commands: commands)
            }
            if let filtered { current = try render(filtered, bounds: bounds, reusing: next(), commands: commands) }
        }
        let output = try filterTexture(bounds: bounds, reusing: previous?.image)
        let pass = try encoder(commands, target: output, clear: MTLClearColorMake(0, 0, 0, 0))
        copy(current, gain: 1, flip: false, encoder: pass)
        pass.endEncoding()
        return ProcessedImage(key: key, image: output)
    }

    private func copy(_ source: MTLTexture, gain: Float, flip: Bool, additive: Bool = false, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(additive ? chainEmissionPipeline : chainCopyPipeline)
        encoder.setFragmentTexture(source, index: 0)
        var values = SIMD2(gain, flip ? Float(1) : 0)
        encoder.setFragmentBytes(&values, length: MemoryLayout.size(ofValue: values), index: 0)
        quad(encoder)
    }

    private func merge(_ source: MTLTexture, into target: MTLTexture, gain: Float = 1, flip: Bool = false,
                       padding: Double = 0, additive: Bool = false, commands: MTLCommandBuffer) throws {
        let pass = try encoder(commands, target: target, clear: MTLClearColorMake(0, 0, 0, 0), load: true)
        if flip {
            pass.setViewport(MTLViewport(originX: padding, originY: padding, width: canvas.width, height: canvas.height, znear: 0, zfar: 1))
        }
        copy(source, gain: gain, flip: flip, additive: additive, encoder: pass)
        pass.endEncoding()
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

    private func bloom(_ image: MTLTexture, threshold level: Double, radius: Double, bounds: CGRect, commands: MTLCommandBuffer) throws -> MTLTexture {
        let emission = try filterTexture(bounds: bounds, reusing: bloomScratch)
        bloomScratch = emission
        guard let encoder = commands.makeComputeCommandEncoder() else { throw Self.renderError }
        encoder.setComputePipelineState(highlight)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(emission, index: 1)
        var threshold = Float(level)
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        let columns = highlight.threadExecutionWidth
        let rows = max(1, highlight.maxTotalThreadsPerThreadgroup / columns)
        encoder.dispatchThreadgroups(MTLSize(width: (image.width + columns - 1) / columns,
                                            height: (image.height + rows - 1) / rows, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: columns, height: rows, depth: 1))
        encoder.endEncoding()
        guard let glow = CIImage(mtlTexture: emission, options: [.colorSpace: Self.linearRGB]) else { throw Self.renderError }
        let output = try render(glow.applyingGaussianBlur(sigma: radius * scale), bounds: bounds, reusing: glowScratch, commands: commands)
        glowScratch = output
        return output
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

    private func drawImageParticles(_ node: EffectNode, texture: MTLTexture, at localTime: Double,
                                    encoder: MTLRenderCommandEncoder) throws {
        guard let appearance = node.particleAppearance else { return }
        let aspect = SIMD2(Float(texture.width), Float(texture.height)) / Float(max(texture.width, texture.height))
        encoder.setRenderPipelineState(appearance.blend == .normal ? particleImagePipeline : particleImageAddPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        for records in node.imageParticleInstances(at: localTime, aspect: aspect) where !records.isEmpty {
            let buffer = records.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            guard let buffer else { throw Self.renderError }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: records.count)
        }
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
