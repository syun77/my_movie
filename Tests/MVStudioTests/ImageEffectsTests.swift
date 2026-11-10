import AppKit
import Metal
import simd
import XCTest
@testable import MVStudio

final class ImageEffectsTests: XCTestCase {
    func testProjectRoundTripAndTrimPreserveParticlePhase() throws {
        let size = SIMD2(1920.0, 1080.0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("song.wav")
        let url = ProjectStorage.projectURL(for: audio)
        let suite = "MVStudioEffects." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStorage(defaults: defaults)
        var images = ImageTrack()
        let asset = images.register(url: directory.appendingPathComponent("image.png"), projectURL: url)
        var clip = ImageClip(assetID: asset, start: 1, end: 4)
        let particles = ImageEffects.Particles(curveStrength: 160, seed: 42)
        clip.effects = ImageEffects(blur: .init(isEnabled: false), bloom: .init(), particles: particles)
        let before = particles.instances(at: 1.5, size: size)
        clip.trimStart(to: 2)
        images.layers[0].clips = [clip]
        try store.save(ProjectFile(audioURL: audio, images: images, settings: SceneSettings(), projectURL: url), to: url)
        let saved = try store.read(from: url)
        XCTAssertEqual(saved.version, 5)
        XCTAssertEqual(saved.images.clips, [clip])
        let restored = try XCTUnwrap(saved.images.clips.first?.effects?.particles)
        _ = restored.instances(at: -1.75, size: size)
        XCTAssertEqual(restored.instances(at: 0.5, size: size), before)
        XCTAssertNotEqual(restored.instances(at: 0, size: size), before)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy["version"] = 4
        var layers = try XCTUnwrap(legacy["imageLayers"] as? [[String: Any]])
        var clips = try XCTUnwrap(layers[0]["clips"] as? [[String: Any]])
        let effects = try XCTUnwrap(clips[0]["effects"] as? [String: Any])
        var savedParticles = try XCTUnwrap(effects["particles"] as? [String: Any])
        savedParticles.removeValue(forKey: "curveStrength")
        savedParticles.removeValue(forKey: "emitters")
        let defaulted = try JSONDecoder().decode(ImageEffects.Particles.self, from: JSONSerialization.data(withJSONObject: savedParticles))
        XCTAssertEqual(defaulted.curveStrength, 100)
        XCTAssertEqual(defaulted.seed, particles.seed)
        XCTAssertEqual(defaulted.emitters, [.init()])
        clips[0].removeValue(forKey: "effects")
        layers[0]["clips"] = clips
        legacy["imageLayers"] = layers
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let decoded = try store.read(from: url)
        XCTAssertNil(decoded.images.clips.first?.effects)
        try store.save(decoded, to: url)
        XCTAssertEqual(try store.read(from: url).version, 5)

        images.layers[0].clips[0].effects?.particles?.curveStrength = 201
        XCTAssertThrowsError(try images.validate())
        images.layers[0].clips[0].effects?.particles?.curveStrength = 160
        images.layers[0].clips[0].effects?.particles?.count = 200.5
        XCTAssertThrowsError(try images.validate())
    }

    func testParticlesTrailMovingLightAndRespectCurveStrength() throws {
        let size = SIMD2(1920.0, 1080.0)
        var particles = ImageEffects.Particles(seed: 42)
        let initial = particles.instances(at: 0, size: size)
        let diameters = initial.map(\.z)
        XCTAssertLessThan(try XCTUnwrap(diameters.min()), Float(particles.diameter * 0.7))
        XCTAssertGreaterThan(try XCTUnwrap(diameters.max()), Float(particles.diameter * 1.3))
        XCTAssertEqual(particles.instances(at: 24, size: size).map(\.z), diameters)
        let head = try XCTUnwrap(initial.first)
        XCTAssertGreaterThan(head.z, try XCTUnwrap(diameters.dropFirst().max()))
        XCTAssertGreaterThan(head.w, try XCTUnwrap(initial.dropFirst().map(\.w).max()))
        XCTAssertNotEqual(particles.instances(at: 1, size: size).map(\.w), initial.map(\.w))

        func position(_ particle: SIMD4<Float>) -> SIMD2<Double> {
            SIMD2(Double(particle.x), Double(particle.y))
        }
        let interval = 0.25
        let next = particles.instances(at: interval, size: size)
        let travel = zip(initial, next).map { simd_length(position($1) - position($0)) }
        XCTAssertGreaterThan(try XCTUnwrap(travel.max()), 2 * (try XCTUnwrap(travel.min())))

        let positions = (0...96).map { position(particles.instances(at: Double($0) * interval, size: size)[0]) }
        let steps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        let speeds = steps.map { simd_length($0) / interval }
        XCTAssertGreaterThan(try XCTUnwrap(speeds.max()), 2 * (try XCTUnwrap(speeds.min())))
        let changes = zip(speeds, speeds.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(changes.contains { $0 > 0.1 })
        XCTAssertTrue(changes.contains { $0 < -0.1 })
        XCTAssertTrue(zip(steps, steps.dropFirst()).contains { a, b in
            abs(a.x * b.y - a.y * b.x) > 0.5
        })

        particles.curveStrength = 0
        let straightPositions = (0...96).map { position(particles.instances(at: Double($0) * interval, size: size)[0]) }
        let straightSteps = zip(straightPositions, straightPositions.dropFirst()).map { $1 - $0 }
        let straightSpeeds = straightSteps.map { simd_length($0) / interval }
        XCTAssertGreaterThan(try XCTUnwrap(straightSpeeds.max()), 2 * (try XCTUnwrap(straightSpeeds.min())))
        let direction = simd_normalize(try XCTUnwrap(straightPositions.last) - straightPositions[0])
        for point in straightPositions {
            let offset = point - straightPositions[0]
            XCTAssertEqual(offset.x * direction.y - offset.y * direction.x, 0, accuracy: 0.02)
        }

        particles.curveStrength = 200
        let curved = particles.instances(at: 2, size: size)[0]
        let normalSway = simd_length(positions[8] - straightPositions[8])
        XCTAssertGreaterThan(normalSway, 1)
        XCTAssertEqual(simd_length(position(curved) - straightPositions[8]), 2 * normalSway, accuracy: 0.03)
        XCTAssertTrue(particles.instances(at: -3, size: size).allSatisfy { $0.x.isFinite && $0.y.isFinite })

        particles.speed = 0
        let stationary = particles.instances(at: 0, size: size)
        let later = particles.instances(at: 4, size: size)
        XCTAssertEqual(stationary.map(position), later.map(position))
        XCTAssertNotEqual(stationary.map(\.w), later.map(\.w))
    }

    func testParticleEmittersKeepSeparateCentersAndPhases() throws {
        let size = SIMD2(1920.0, 1080.0)
        var particles = ImageEffects.Particles(seed: 42)
        let first = particles.emitters[0]
        let original = particles.instances(at: 1, size: size, emitter: first)
        particles.addEmitter()
        var second = try XCTUnwrap(particles.emitters.last)
        XCTAssertNotEqual(second.phaseSeed, 0)
        XCTAssertEqual(particles.instances(at: 1, size: size, emitter: first), original)
        let secondBefore = particles.instances(at: 1, size: size, emitter: second)
        second.x -= 320
        second.y += 150
        particles.emitters[1] = second
        let shifted = particles.instances(at: 1, size: size, emitter: second)
        XCTAssertEqual(shifted[0].x - secondBefore[0].x, -320, accuracy: 0.001)
        XCTAssertEqual(shifted[0].y - secondBefore[0].y, 150, accuracy: 0.001)
        XCTAssertEqual(shifted.count, Int(particles.count))

        for _ in 0..<4 { particles.addEmitter() }
        XCTAssertEqual(particles.emitters.count, 4)
        let decoded = try JSONDecoder().decode(ImageEffects.Particles.self, from: JSONEncoder().encode(particles))
        XCTAssertEqual(decoded, particles)
        XCTAssertEqual(decoded.instances(at: 1, size: size, emitter: decoded.emitters[1]), shifted)
        particles.emitters[1].x = -1
        XCTAssertFalse(ImageEffects(particles: particles).isValid)
        particles.emitters = []
        XCTAssertFalse(ImageEffects(particles: particles).isValid)
    }

    func testEmbersRiseAndPreservePhaseAfterTrimAndReload() throws {
        let size = SIMD2(1920.0, 1080.0)
        var embers = ImageEffects.Embers(swaySpeed: 100, seed: 77)
        let first = embers.instances(at: 1.5, size: size)
        let later = embers.instances(at: 1.6, size: size)
        XCTAssertEqual(first.count, 90)
        XCTAssertGreaterThan(Set(first.map(\.z)).count, 1)
        XCTAssertGreaterThan(zip(first, later).filter { $1.y < $0.y }.count, 80)
        XCTAssertTrue(first.allSatisfy { (0...1).contains($0.w) })
        XCTAssertNotEqual(first.map(\.w), later.map(\.w))
        func riseVariation(_ settings: ImageEffects.Embers) -> Double {
            let frames = [1.5, 1.6, 1.7].map { settings.instances(at: $0, size: size) }
            return zip(zip(frames[0], frames[1]), frames[2]).reduce(0) { total, entry in
                let ((a, b), c) = entry
                return a.y > b.y && b.y > c.y ? total + Double(abs((a.y - b.y) - (b.y - c.y))) : total
            }
        }
        var slower = embers
        slower.swaySpeed = 40
        var straight = embers
        straight.swaySpeed = 0
        XCTAssertLessThan(riseVariation(slower), riseVariation(embers))
        XCTAssertEqual(riseVariation(straight), 0, accuracy: 0.01)
        XCTAssertEqual(slower.instances(at: 1.5, size: size).map(\.w), first.map(\.w))
        XCTAssertEqual(embers.instances(at: 1.5, size: size), first)

        var clip = ImageClip(assetID: UUID(), start: 1, end: 5, effects: ImageEffects(embers: embers))
        clip.trimStart(to: 2)
        let restored = try JSONDecoder().decode(ImageClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(restored, clip)
        XCTAssertEqual(restored.effects?.embers?.instances(at: 0.5, size: size), first)
        let beforeStart = embers.instances(at: -8, size: size)
        XCTAssertTrue(beforeStart.allSatisfy { $0.x.isFinite && $0.y.isFinite })

        var savedEmbers = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(embers)) as? [String: Any])
        savedEmbers.removeValue(forKey: "swaySpeed")
        let defaulted = try JSONDecoder().decode(ImageEffects.Embers.self, from: JSONSerialization.data(withJSONObject: savedEmbers))
        XCTAssertEqual(defaulted.swaySpeed, 40)
        embers.swaySpeed = 201
        XCTAssertFalse(ImageEffects(embers: embers).isValid)
        embers.swaySpeed = 100
        embers.wind = 241
        XCTAssertFalse(ImageEffects(embers: embers).isValid)
    }

    func testMetalCompositionBlurBloomAndParticleLayering() throws {
        let renderer = try MetalSceneRenderer()
        let width = VideoExporter.width, height = VideoExporter.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))

        func image(_ paint: (CGContext) -> Void) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                                space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            paint(context)
            return try XCTUnwrap(context.makeImage())
        }

        func render(_ layers: [ImageRenderLayer], time: Double = 0.5) throws {
            let buffer = try renderer.encode(images: layers, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(),
                                             time: time, target: target, video: false)
            if target.storageMode != .shared {
                let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
                blit.synchronize(resource: target)
                blit.endEncoding()
            }
            buffer.commit()
            buffer.waitUntilCompleted()
            if buffer.status != .completed { throw buffer.error ?? MetalSceneRenderer.renderError }
        }

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            var bgra = [UInt8](repeating: 0, count: 4)
            target.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bgra
        }

        let spot = try image { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 4, y: 10, width: 8, height: 4))
        }
        var clip = ImageClip(assetID: UUID(), start: 0, end: 1, automaticAnimation: .off)
        func layer() -> ImageRenderLayer { ImageRenderLayer(clip: clip, image: spot) }
        try render([layer()])
        XCTAssertGreaterThan(pixel(960, 270)[0], 245)
        let background = pixel(960, 650)
        XCTAssertLessThan(background[0], 25)
        let edge = pixel(650, 270)[0]
        clip.fixedValues[.rotation] = 90
        try render([layer()])
        XCTAssertGreaterThan(pixel(1230, 540)[0], 245)
        XCTAssertEqual(pixel(960, 270), background)
        clip.fixedValues[.rotation] = nil

        clip.effects = ImageEffects(blur: .init(radius: 20))
        try render([layer()])
        XCTAssertGreaterThan(pixel(650, 270)[0], edge)
        XCTAssertLessThan(pixel(700, 270)[0], 245)

        clip.effects = ImageEffects(bloom: .init(radius: 30, intensity: 200))
        try render([layer()])
        XCTAssertGreaterThan(pixel(650, 270)[0], edge)
        XCTAssertEqual(pixel(960, 650), background)
        clip.effects?.bloom?.isEnabled = false
        try render([layer()])
        XCTAssertEqual(pixel(650, 270)[0], edge)

        let red = try image { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let halfBlue = try image { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var lower = clip
        lower.effects = nil
        var upper = lower
        upper.id = UUID()
        try render([ImageRenderLayer(clip: lower, image: red), ImageRenderLayer(clip: upper, image: halfBlue)])
        XCTAssertEqual(Double(pixel(960, 540)[0]), 188, accuracy: 3)
        XCTAssertEqual(Double(pixel(960, 540)[2]), 188, accuracy: 3)

        let particles = ImageEffects.Particles(count: 1, diameter: 32, opacity: 100, seed: 10)
        clip.effects = ImageEffects(particles: particles)
        let particle = try XCTUnwrap(particles.instances(at: 0.5, size: SIMD2(Double(width), Double(height))).first)
        let x = Int(particle.x), y = Int(particle.y)
        XCTAssertTrue((0..<width).contains(x) && (0..<height).contains(y))
        try render([layer()])
        let lit = pixel(x, y)
        try render([layer()], time: 1)
        XCTAssertNotEqual(lit, pixel(x, y))
        try render([layer()])
        XCTAssertEqual(lit, pixel(x, y))

        var cover = ImageClip(assetID: UUID(), start: 0, end: 1, automaticAnimation: .off)
        cover.fixedValues[.scale] = 200
        let black = try image { context in
            context.setFillColor(.black)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try render([layer(), ImageRenderLayer(clip: cover, image: black)])
        XCTAssertEqual(pixel(x, y), [0, 0, 0, 255])

        var magic = cover
        magic.id = UUID()
        magic.end = 8
        let stationary = ImageEffects.Particles(count: 1, diameter: 32, speed: 0, opacity: 100, seed: 10)
        magic.effects = ImageEffects(particles: stationary)
        let center = stationary.instances(at: 0.5, size: SIMD2(Double(width), Double(height)))[0]
        let mx = Int(center.x), my = Int(center.y)
        let ray = Int(center.z * 0.27)
        let diagonal = Int(Double(ray) / sqrt(2))
        let magicLayer = ImageRenderLayer(clip: magic, image: black)
        try render([magicLayer], time: 0.5)
        let firstHue = pixel(mx + ray, my)
        XCTAssertGreaterThan(firstHue.prefix(3).max() ?? 0, pixel(mx + ray, my + diagonal).prefix(3).max() ?? 0)
        XCTAssertGreaterThan(pixel(mx + diagonal, my + diagonal).prefix(3).max() ?? 0, 0)
        try render([magicLayer], time: 6.5)
        let laterHue = pixel(mx + ray, my)
        XCTAssertNotEqual(firstHue.prefix(3).enumerated().max(by: { $0.element < $1.element })?.offset,
                          laterHue.prefix(3).enumerated().max(by: { $0.element < $1.element })?.offset)

        var twoSources = stationary
        twoSources.emitters = [.init(x: 320, y: 300), .init(x: 950, y: 700, phaseSeed: 42)]
        magic.effects = ImageEffects(particles: twoSources)
        try render([ImageRenderLayer(clip: magic, image: black)])
        for source in twoSources.emitters {
            let point = twoSources.instances(at: 0.5, size: SIMD2(Double(width), Double(height)), emitter: source)[0]
            XCTAssertGreaterThan(pixel(Int(point.x), Int(point.y)).prefix(3).max() ?? 0, 150)
        }

        let embers = ImageEffects.Embers(diameter: 32, brightness: 100, seed: 18)
        var emberClip = cover
        emberClip.id = UUID()
        emberClip.effects = ImageEffects(embers: embers)
        let spark = try XCTUnwrap(embers.instances(at: 0.5, size: SIMD2(Double(width), Double(height))).first {
            $0.x > 50 && $0.x < Float(width - 50) && $0.y > 50 && $0.y < Float(height - 50) && $0.w > 0.4
        })
        let sx = Int(spark.x), sy = Int(spark.y)
        let emberLayer = ImageRenderLayer(clip: emberClip, image: black)
        try render([emberLayer])
        let warm = pixel(sx, sy)
        XCTAssertGreaterThan(warm[2], warm[1])
        XCTAssertGreaterThan(warm[1], warm[0])
        XCTAssertGreaterThan(pixel(sx + Int(spark.z * 0.16), sy)[2], 0)
        try render([emberLayer, ImageRenderLayer(clip: cover, image: black)])
        XCTAssertEqual(pixel(sx, sy), [0, 0, 0, 255])
        emberClip.effects?.embers?.isEnabled = false
        try render([ImageRenderLayer(clip: emberClip, image: black)])
        XCTAssertEqual(pixel(sx, sy), [0, 0, 0, 255])
    }
}
