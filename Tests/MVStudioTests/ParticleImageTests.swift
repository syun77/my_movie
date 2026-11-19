import AppKit
import AVFoundation
import ImageIO
import XCTest
@testable import MVStudio

final class ParticleImageTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/particle-test.mvproject")
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 20, width: 80, height: 20))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 20))
        return try XCTUnwrap(context.makeImage())
    }
    private func track(_ kind: EffectKind = .snow) -> (VisualTrack, VisualClip, UUID) {
        var track = VisualTrack()
        let id = track.register(url: URL(fileURLWithPath: "/tmp/particle.png"), projectURL: projectURL)
        var effects = ImageEffects(); effects.nodes = [EffectNode(payload: kind.initial)]
        var appearance = ParticleAppearance(); appearance.assetID = id; appearance.mode = .image; appearance.size = 240
        effects.setAppearance(appearance, for: kind)
        let clip = VisualClip(start: 0, end: 2, effects: effects)
        track.layers[0].clips = [clip]
        return (track, clip, id)
    }
    private func snapshot(_ canvas: EffectTestCanvas) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: canvas.target.width * canvas.target.height * 4)
        canvas.target.getBytes(&pixels, bytesPerRow: canvas.target.width * 4,
                               from: MTLRegionMake2D(0, 0, canvas.target.width, canvas.target.height), mipmapLevel: 0)
        return pixels
    }

    @MainActor func testAppearanceAutomationHistoryAndRoundTrip() throws {
        for kind in [EffectKind.particles, .embers, .snow, .orbs] {
            var (track, clip, id) = track(kind)
            let parameters = ImageParameter.allCases.filter { $0.effectKind == kind && $0.rawValue.contains("Image") }
            XCTAssertEqual(parameters.count, 4)
            for parameter in parameters {
                let range = parameter.defaultRange
                _ = clip.setKey(parameter, at: 0, value: range.lowerBound)
                _ = clip.setKey(parameter, at: 1, value: range.upperBound)
            }
            let before = clip.evaluatedEffects(at: 0.5)?.appearance(kind)
            XCTAssertNotNil(before)
            clip.trimStart(to: 0.25)
            XCTAssertEqual(clip.evaluatedEffects(at: 0.5)?.appearance(kind), before)
            track.layers[0].clips = [clip]; try track.validate()
            let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), visuals: track, settings: SceneSettings(), projectURL: projectURL)
            let decoded = try ProjectMigrator.read(JSONEncoder().encode(project), at: projectURL).project
            XCTAssertEqual(decoded.visuals, track)
            XCTAssertEqual(decoded.visuals.clips.first?.particleAssetIDs, [id])
            let history = EditHistory(); history.reset(EditSnapshot(visuals: track))
            let removed = try track.removingAsset(id: id, includingPlacements: true)
            history.record(EditSnapshot(visuals: removed))
            XCTAssertEqual(history.undo()?.visuals, track)
            XCTAssertEqual(history.redo()?.visuals, removed)
        }
    }

    func testAssetReferencesReplacementDeletionAndMissingModes() throws {
        var (track, clip, id) = track()
        XCTAssertTrue(track.uses(id).isEmpty); XCTAssertEqual(track.particleUses(id).count, 1)
        XCTAssertThrowsError(try track.removingAsset(id: id, includingPlacements: false))
        let removed = try track.removingAsset(id: id, includingPlacements: true)
        XCTAssertEqual(removed.clips.count, 1); XCTAssertTrue(removed.clips[0].particleAssetIDs.isEmpty)
        XCTAssertFalse(try XCTUnwrap(removed.clips[0].effects?.appearance(.snow)).usesImage)
        let second = track.register(url: URL(fileURLWithPath: "/tmp/second.png"), projectURL: projectURL)
        let merged = try track.replacingAsset(id: id, url: URL(fileURLWithPath: "/tmp/second.png"), projectURL: projectURL)
        XCTAssertEqual(merged.clips[0].particleAssetIDs, [second]); XCTAssertNil(merged.asset(id))
        XCTAssertThrowsError(try track.replacingAsset(id: id, url: URL(fileURLWithPath: "/tmp/a.mov"), projectURL: projectURL, kind: .video(duration: 3)))
        clip.effects?.isBypassed = true
        XCTAssertEqual(clip.particleAssetIDs, [id]); XCTAssertTrue(clip.activeParticleAssetIDs.isEmpty)
        var value = try XCTUnwrap(clip.effects?.appearance(.snow)); value.mode = .standard
        clip.effects?.setAppearance(value, for: .snow)
        XCTAssertTrue(clip.activeParticleAssetIDs.isEmpty)
        value.assetID = nil; value.mode = .image
        let normalized = try JSONDecoder().decode(ParticleAppearance.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(normalized.mode, .standard)
    }

    func testFourRenderersFallbackTintBlendAndSeekDeterminism() throws {
        let canvas = try EffectTestCanvas(scale: 0.1)
        let image = try image()
        for kind in [EffectKind.particles, .embers, .snow, .orbs] {
            let (_, original, id) = track(kind)
            var clip = original
            try canvas.draw([(clip, 1)], particleImages: [id: VisualFrame(image)])
            let pictured = snapshot(canvas)
            try canvas.draw([(clip, 1)])
            let missing = snapshot(canvas)
            var empty = clip; empty.effects = nil
            try canvas.draw([(empty, 1)])
            XCTAssertEqual(missing, snapshot(canvas))
            try canvas.draw([(clip, 1)], time: 1.2, particleImages: [id: VisualFrame(image)])
            try canvas.draw([(clip, 1)], particleImages: [id: VisualFrame(image)])
            XCTAssertEqual(pictured, snapshot(canvas))
            var value = try XCTUnwrap(clip.effects?.appearance(kind))
            value.angle = 90; value.spread = 45; value.spin = 90; value.blend = .additive; value.colorMode = .effect
            clip.effects?.setAppearance(value, for: kind)
            try canvas.draw([(clip, 1)], particleImages: [id: VisualFrame(image)])
            XCTAssertNotEqual(pictured, snapshot(canvas))
            value.assetID = nil; clip.effects?.setAppearance(value, for: kind)
            try canvas.draw([(clip, 1)])
            let fallback = snapshot(canvas)
            let nodeID = try XCTUnwrap(clip.effects?.nodes.first?.id)
            clip.effects?.editNode(nodeID) { $0.particleAppearance = nil }
            try canvas.draw([(clip, 1)])
            XCTAssertEqual(fallback, snapshot(canvas)); XCTAssertNotEqual(pictured, fallback)
        }
    }

    func testAspectOrientationAlphaAndDownstreamBlur() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var (_, clip, id) = track()
        // Select a seeded particle well inside the output frame.
        let seed = try XCTUnwrap((UInt32(0)...100).first { seed in
            let p = ImageEffects.Snow(count: 1, seed: seed).instances(at: 0.5, size: SIMD2(1920, 1080))[0]
            return p.x > 600 && p.x < 1300 && p.y > 350 && p.y < 730
        })
        clip.effects?.snow = .init(count: 1, seed: seed)
        let p = try XCTUnwrap(clip.effects?.snow?.instances(at: 0.5, size: SIMD2(1920, 1080)).first)
        var appearance = try XCTUnwrap(clip.effects?.appearance(.snow)); appearance.size = 400
        clip.effects?.setAppearance(appearance, for: .snow)
        let images = [id: VisualFrame(try image())]
        try canvas.draw([(clip, 1)], particleImages: images)
        let x = Int(p.x * 0.25), y = Int(p.y * 0.25)
        let upper = canvas.pixel(x, y - 4), lower = canvas.pixel(x, y + 4)
        XCTAssertGreaterThan(upper[2], upper[1]); XCTAssertGreaterThan(lower[1], lower[2])
        XCTAssertGreaterThan(upper[2], lower[1])
        let picture = snapshot(canvas)
        clip.effects?.blur = .init(radius: 30)
        try canvas.draw([(clip, 1)], particleImages: images)
        XCTAssertNotEqual(picture, snapshot(canvas))
        try canvas.save("/tmp/my-movie-particle-render.png")
    }

    func testProviderMissingAndPinnedExportImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("particle.png")
        let bitmap = NSBitmapImageRep(cgImage: try image())
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        var (track, clip, id) = track()
        track = try track.replacingAsset(id: id, url: url, projectURL: projectURL)
        let provider = VisualFrameProvider()
        try await provider.validateUsed(track: track, projectURL: projectURL, cancellation: ExportCancellation())
        try FileManager.default.removeItem(at: url)
        let layers = try await provider.layers(track: track, projectURL: projectURL, time: 0.5, allowMissingImages: false)
        XCTAssertNotNil(layers.first?.particleImages[id])
        let preview = VisualFrameProvider()
        let missing = try await preview.layers(track: track, projectURL: projectURL, time: 0.5, allowMissingImages: true)
        XCTAssertTrue(try XCTUnwrap(missing.first).particleImages.isEmpty)
        do { try await VisualAssetLoader().validateUsed(track: track, projectURL: projectURL); XCTFail("Missing active image must fail") } catch {}
        clip.effects?.isBypassed = true; track.layers[0].clips = [clip]
        try await VisualAssetLoader().validateUsed(track: track, projectURL: projectURL)
    }
    @MainActor func testImportAndCrossProjectClipboard() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("particle.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage: image()).representation(using: .png, properties: [:])).write(to: url)
        let editor = PlacementEditor(); _ = editor.view
        editor.duration = 10; editor.restoreTab(.visuals); editor.setAvailable(hasAudio: true, isBusy: false)
        let clip = VisualClip(start: 0, end: 1, effects: ImageEffects(snow: .init(seed: 0)))
        var track = VisualTrack(); track.layers[0].clips = [clip]
        editor.visuals.load(track, projectURL: directory.appendingPathComponent("source.mvproject"))
        editor.timeline.onImageSelect?(clip.id, editor.timeline.visuals.layers[0].id)
        editor.visuals.importFile(url, particleNode: try XCTUnwrap(clip.effects?.nodes.first?.id))
        for _ in 0..<300 { if !editor.visuals.isProcessing { break }; try await Task.sleep(for: .milliseconds(10)) }
        let imported = try XCTUnwrap(editor.visuals.track.clips.first)
        let sourceID = try XCTUnwrap(imported.particleAssetIDs.first)
        XCTAssertEqual(editor.visuals.track.clips.count, 1); XCTAssertEqual(editor.visuals.track.assets.count, 1)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        editor.editClip(.copy, pasteboard: pasteboard)
        let destination = directory.appendingPathComponent("other/project.mvproject")
        editor.visuals.load(VisualTrack(), projectURL: destination)
        editor.currentTime = 3
        editor.editClip(.paste, pasteboard: pasteboard)
        let copied = try XCTUnwrap(editor.visuals.track.clips.first)
        let copiedID = try XCTUnwrap(copied.particleAssetIDs.first)
        XCTAssertNotEqual(sourceID, copiedID)
        XCTAssertNotEqual(imported.effects?.nodes.first?.id, copied.effects?.nodes.first?.id)
        XCTAssertEqual(editor.visuals.track.asset(copiedID)?.reference.resolve(projectURL: destination), url)
        XCTAssertEqual(copied.effects?.appearance(.snow)?.mode, .image)
    }

    func testExportParticleImagesMatchesPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("main.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
        pcm.frameLength = 9600; pcm.floatChannelData![0].initialize(repeating: 0, count: 9600)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        let url = directory.appendingPathComponent("particle.png")
        let picture = try image()
        try XCTUnwrap(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])).write(to: url)
        var (track, clip, id) = track()
        track = try track.replacingAsset(id: id, url: url, projectURL: projectURL)
        clip.end = 0.2; clip.effects?.snow = .init(count: 30, diameter: 22, seed: 4)
        var appearance = try XCTUnwrap(clip.effects?.appearance(.snow)); appearance.size = 200
        clip.effects?.setAppearance(appearance, for: .snow)
        track.layers[0].clips = [clip]
        let features = AudioFeatures(duration: 0.2, step: 0.1, frames: [], transientEvents: [TransientBand(): []])
        let output = directory.appendingPathComponent("particles.mp4")
        try await VideoExporter.export(visuals: track, projectURL: projectURL, audioURL: audio, features: features,
                                       settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), destination: output,
                                       cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let movies = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: try XCTUnwrap(movies.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let canvas = try EffectTestCanvas()
        var count = 0
        while let sample = decoded.copyNextSampleBuffer() {
            let time = Double(count) / 30
            try canvas.draw([(clip, 1)], time: time, video: true, particleImages: [id: VisualFrame(picture)])
            let buffer = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            var difference = 0.0, samples = 0
            for y in stride(from: 20, to: 1080, by: 40) {
                for x in stride(from: 20, to: 1920, by: 40) {
                    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                    let expected = canvas.pixel(x, y)
                    for c in 0..<3 { difference += abs(Double(base[offset + c]) - Double(expected[c])); samples += 1 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            XCTAssertLessThan(difference / Double(samples), 6)
            count += 1
        }
        XCTAssertEqual(count, 6); XCTAssertEqual(reader.status, .completed)
    }

    func testMaximumParticleLayersPerformance() throws {
        let canvas = try EffectTestCanvas()
        let picture = try image()
        var clips: [(VisualClip, Int)] = [], images: [UUID: VisualFrame] = [:]
        for slot in 1...3 {
            var (_, clip, id) = track(.particles)
            var particles = ImageEffects.Particles(count: 200, seed: UInt32(slot))
            for _ in 0..<3 { particles.addEmitter() }
            clip.effects?.particles = particles
            clips.append((clip, slot)); images[id] = VisualFrame(picture)
        }
        var maximum = 0.0
        for frame in 0..<30 {
            try canvas.draw(clips, time: Double(frame) / 30, particleImages: images)
            maximum = max(maximum, canvas.lastGPUMS)
        }
        print("Particle image 1080p / 3 layers / 4 emitters / 200 particles: GPU max \(maximum)ms")
    }

    func testGeometryAspectRotationAndTrimPhase() throws {
        var (_, clip, _) = track(.snow)
        var appearance = try XCTUnwrap(clip.effects?.appearance(.snow))
        appearance.angle = 20; appearance.spread = 90; appearance.spin = 60
        clip.effects?.setAppearance(appearance, for: .snow)
        let node = try XCTUnwrap(clip.effects?.nodes.first)
        let before = node.imageParticleInstances(at: 0.5, aspect: SIMD2(1, 0.5))
        let particle = try XCTUnwrap(before.first?.first)
        XCTAssertEqual(particle.geometry.z / particle.geometry.w, 2, accuracy: 1e-6)
        clip.trimStart(to: 0.25)
        let after = try XCTUnwrap(clip.effects?.nodes.first).imageParticleInstances(at: 0.25, aspect: SIMD2(1, 0.5))
        XCTAssertEqual(before.first?.map(\.geometry), after.first?.map(\.geometry))
        XCTAssertEqual(before.first?.map(\.motion), after.first?.map(\.motion))
    }

}
