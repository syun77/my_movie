import AppKit
import AVFoundation
import Metal
import XCTest
@testable import MVStudio

final class CrossfadeTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/crossfade.mvproject")
    private func pair() -> (VisualClip, VisualClip) {
        (VisualClip(start: 0, end: 3), VisualClip(start: 2, end: 5))
    }
    func testIntervalsWeightsAndInvalidArrangements() throws {
        let (a, b) = pair()
        let transition = try XCTUnwrap(LayerCrossfade(a, b))
        XCTAssertEqual(transition.duration, 1)
        for (time, value) in [(1.0, 0.0), (2, 0), (2.25, 0.15625), (2.5, 0.5), (3, 1), (4, 1)] {
            XCTAssertEqual(transition.incomingWeight(at: time), value, accuracy: 1e-12)
        }
        var track = VisualTrack(); track.layers[0].clips = [a, b]
        try track.validate(duration: 8)
        XCTAssertEqual(track.active(at: 2).map(\.id), [a.id, b.id])
        XCTAssertEqual(track.active(at: 3).map(\.id), [b.id])
        track.layers[0].clips.append(VisualClip(start: 3, end: 6))
        try track.validate(duration: 8)
        XCTAssertEqual(LayerCrossfade.transitions(in: track.layers[0].clips).count, 2)
        for invalid in [[a, VisualClip(start: 1, end: 2)], [a, VisualClip(start: 0, end: 4)],
                        [a, VisualClip(start: 2, end: 3)], [a, b, VisualClip(start: 2.5, end: 6)], [b, a]] {
            track.layers[0].clips = invalid; XCTAssertThrowsError(try track.validate(duration: 8))
        }
        track.layers[0].clips = [a, VisualClip(start: 3, end: 5)]
        try track.validate(); XCTAssertTrue(LayerCrossfade.transitions(in: track.layers[0].clips).isEmpty)
        track.layers[0].clips[1].start = 2.999
        XCTAssertEqual(try XCTUnwrap(LayerCrossfade.transitions(in: track.layers[0].clips).first).duration, 0.001, accuracy: 1e-12)
        track.layers[0].isVisible = false
        XCTAssertTrue(track.active(at: 2.9995).isEmpty)
    }

    @MainActor func testEditingStorageAndHistory() throws {
        let (a, b) = pair()
        var track = VisualTrack(); track.layers[0].clips = [a, b]
        let moved = try track.dragging(id: b.id, part: .move, delta: -0.5, duration: 8, grid: TimelineSnapGrid())
        XCTAssertEqual(try XCTUnwrap(LayerCrossfade.transitions(in: moved.layers[0].clips).first).duration, 1.5)
        let trimmed = try track.dragging(id: a.id, part: .end, delta: -1, duration: 8, grid: TimelineSnapGrid())
        XCTAssertTrue(LayerCrossfade.transitions(in: trimmed.layers[0].clips).isEmpty)
        var empty = VisualTrack()
        empty = try empty.addingEmpty(at: 0, layerID: empty.layers[0].id, duration: 8, grid: TimelineSnapGrid()).track
        let added = try empty.addingEmpty(at: 1, layerID: empty.layers[0].id, duration: 8, grid: TimelineSnapGrid())
        XCTAssertEqual(added.track.active(at: 1.5).count, 2)
        let history = EditHistory()
        history.reset(EditSnapshot(lyrics: LyricsTrack(), visuals: track, settings: SceneSettings()))
        history.record(EditSnapshot(lyrics: LyricsTrack(), visuals: moved, settings: SceneSettings()))
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertEqual(history.redo()?.visuals, moved)
    }

    func testProjectRoundTripAndLegacyOverlapRejection() throws {
        let (a, b) = pair()
        var track = VisualTrack(); track.layers[0].clips = [a, b]
        let file = ProjectFile(audioURL: project.deletingPathExtension(), visuals: track, settings: SceneSettings(), projectURL: project)
        let data = try JSONEncoder().encode(file)
        let restored = try ProjectMigrator.read(data, at: project)
        XCTAssertEqual(restored.project.visuals, track)
        XCTAssertEqual(restored.project.version, 21)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["version"] = 20
        XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root), at: project))
        root["version"] = 17
        XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root), at: project))
    }

    func testOpaqueAndTransparentMixDoesNotRevealBackground() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var (a, b) = pair()
        a.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 1, green: 0, blue: 0)))
        b.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 0, green: 0, blue: 1)))
        try canvas.draw([(a, 1), (b, 1)], time: 2.5)
        let mixed = canvas.pixel(240, 135)
        XCTAssertEqual(Double(mixed[0]), 188, accuracy: 2)
        XCTAssertEqual(Double(mixed[2]), 188, accuracy: 2)
        XCTAssertLessThan(mixed[1], 2)
        b.effects = a.effects
        try canvas.draw([(a, 1)], time: 2.5)
        let original = canvas.pixel(240, 135)
        try canvas.draw([(a, 1), (b, 1)], time: 2.5)
        XCTAssertEqual(canvas.pixel(240, 135), original)
        a.fixedValues[.opacity] = 50; b.fixedValues[.opacity] = 50
        try canvas.draw([(a, 1)], time: 2.5)
        let translucent = canvas.pixel(240, 135)
        try canvas.draw([(a, 1), (b, 1)], time: 2.5)
        XCTAssertEqual(canvas.pixel(240, 135), translucent)
        a.fixedValues[.opacity] = 0
        try canvas.draw([(a, 1), (b, 1)], time: 2.5)
        XCTAssertLessThan(canvas.pixel(240, 135)[2], translucent[2])
        try canvas.save("/tmp/my-movie-crossfade-render.png")
    }

    func testCrossfadingMaskOwnersAndMaskedLowerPair() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var (a, b) = pair()
        a.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 1, green: 0, blue: 0)))
        b.effects = a.effects
        var (ownerA, ownerB) = pair()
        ownerA.effects = ImageEffects(belowMask: .init(geometry: ShapeGeometry(width: 0)))
        try canvas.draw([(a, 0), (b, 0)], time: 2.5)
        let unmasked = canvas.pixel(240, 135)
        try canvas.draw([(a, 0), (b, 0), (ownerA, 1), (ownerB, 1)], time: 2.5)
        let halfMask = canvas.pixel(240, 135)
        XCTAssertEqual(Double(halfMask[2]), 188, accuracy: 2)
        XCTAssertLessThan(halfMask[2], unmasked[2])
        ownerA.fixedValues[.opacity] = 0
        try canvas.draw([(a, 0), (b, 0), (ownerA, 1), (ownerB, 1)], time: 2.5)
        XCTAssertEqual(canvas.pixel(240, 135), unmasked)
        ownerA.fixedValues[.opacity] = 100
        ownerB.effects = ownerA.effects
        try canvas.draw([(a, 0), (b, 0), (ownerA, 1), (ownerB, 1)], time: 2.5)
        XCTAssertLessThan(canvas.pixel(240, 135)[2], 15)
        try canvas.draw([(a, 0), (b, 0), (ownerA, 2), (ownerB, 2)], time: 2.5)
        XCTAssertEqual(canvas.pixel(240, 135), unmasked, "空段を飛ばさない")
    }

    @MainActor func testTimelineSelectionTrimPreviewCancelAndDrawing() throws {
        _ = NSApplication.shared
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 240))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        view.visualMode = true; view.isEnabled = true; view.duration = 10
        let (a, b) = pair(); view.visuals.layers[0].clips = [a, b]
        view.onImageSelect = { view.selectedImageID = $0; view.selectedLayerID = $1 }
        var commits = 0; var preview: VisualTrack?
        view.onImagePreview = { preview = $0 }
        view.onImageCommit = { value, _ in view.visuals = value; commits += 1 }
        func event(_ type: NSEvent.EventType, _ t: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.x(at: t), y: 160), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 2.25)); view.mouseUp(with: event(.leftMouseUp, 2.25))
        XCTAssertEqual(view.selectedImageID, a.id)
        view.mouseDown(with: event(.leftMouseDown, 2.75)); view.mouseUp(with: event(.leftMouseUp, 2.75))
        XCTAssertEqual(view.selectedImageID, b.id)
        view.mouseDown(with: event(.leftMouseDown, 2)); view.mouseDragged(with: event(.leftMouseDragged, 1.5))
        XCTAssertEqual(preview?.clip(b.id)?.start, 1.5)
        view.cancelDrag(); XCTAssertEqual(preview, view.visuals); XCTAssertEqual(commits, 0)
        view.mouseDown(with: event(.leftMouseDown, 2)); view.mouseDragged(with: event(.leftMouseDragged, 1.5)); view.mouseUp(with: event(.leftMouseUp, 1.5))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(view.visuals.clip(b.id)?.start, 1.5)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/my-movie-crossfade-timeline.png"))
    }

    func testAdditiveLightAndStillPreviewReuse() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var (a, b) = pair()
        var particles = ImageEffects.SpiralParticles(); particles.speed = 0
        a.effects = ImageEffects(spiralParticles: particles); b.effects = a.effects
        try canvas.draw([(a, 1)], time: 2.5)
        func bytes() -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: canvas.target.width * canvas.target.height * 4)
            canvas.target.getBytes(&pixels, bytesPerRow: canvas.target.width * 4,
                                   from: MTLRegionMake2D(0, 0, canvas.target.width, canvas.target.height), mipmapLevel: 0)
            return pixels
        }
        let single = bytes()
        XCTAssertGreaterThan(stride(from: 0, to: single.count, by: 4).map { single[$0] }.max() ?? 0, 50)
        try canvas.draw([(a, 1), (b, 1)], time: 2.5)
        let mixed = bytes()
        XCTAssertLessThanOrEqual(zip(single, mixed).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        var track = VisualTrack(); track.layers[0].clips = [a, b]
        let layers = [VisualRenderLayer(clip: a, image: canvas.transparent), VisualRenderLayer(clip: b, image: canvas.transparent)]
        let reused = try XCTUnwrap(PreviewFrameReuse.stills(layers, track: track, time: 2.5))
        XCTAssertEqual(reused.map(\.clip.id), [a.id, b.id])
        XCTAssertEqual(Set(reused.map(\.layerID)), [track.layers[0].id])
        XCTAssertNil(PreviewFrameReuse.stills(Array(layers.prefix(1)), track: track, time: 2.5))
    }

    func testFiftyLayerValidationAndMultipleTransitionRendering() throws {
        var track = VisualTrack(); track.layers = (0..<50).map { VisualLayer(name: "段 \($0)") }
        for index in track.layers.indices {
            let (a, b) = pair(); track.layers[index].clips = [a, b]
        }
        try track.validate(duration: 5)
        XCTAssertEqual(track.active(at: 2.5).count, 100)
        let canvas = try EffectTestCanvas(scale: 0.25)
        var items: [(VisualClip, Int)] = []
        for index in 0..<3 {
            var (a, b) = pair()
            a.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 1, green: 0, blue: 0)))
            b.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 0, green: 0, blue: 1)))
            items += [(a, index), (b, index)]
        }
        try canvas.draw(items, time: 2.5)
        XCTAssertEqual(Double(canvas.pixel(240, 135)[2]), 188, accuracy: 2)
        print("Crossfade 3 layers, 480x270: CPU \(canvas.lastEncodeMS)ms GPU \(canvas.lastGPUMS)ms; shared RGBA16F composition surface 1036800 bytes")
    }

    func testTwoVideoCrossfadeMP4MatchesRenderer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("source.mov")
        try await VideoTestFixtures.makeVideo(movie, codec: .h264, times: [0, 0.1, 0.2, 0.3], end: 0.5)
        let audio = directory.appendingPathComponent("audio.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 19200))
        pcm.frameLength = 19200; pcm.floatChannelData![0].initialize(repeating: 0, count: 19200)
        do { let writer = try AVAudioFile(forWriting: audio, settings: format.settings); try writer.write(from: pcm) }
        var track = VisualTrack()
        let id = track.register(url: movie, projectURL: project, kind: .video(duration: 0.5))
        let a = VisualClip(assetID: id, start: 0, end: 0.3, content: .video(sourceIn: 0.1))
        let b = VisualClip(assetID: id, start: 0.1, end: 0.4, content: .video(sourceIn: 0))
        track.layers[0].clips = [a, b]
        let features = AudioFeatures(duration: 0.4, step: 0.1, frames: [], transientEvents: [TransientBand(): []])
        let output = directory.appendingPathComponent("crossfade.mp4")
        try await VideoExporter.export(visuals: track, projectURL: project, audioURL: audio, features: features,
                                       settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), destination: output,
                                       cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        XCTAssertEqual(audioTracks.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let provider = VisualFrameProvider(), canvas = try EffectTestCanvas()
        var count = 0
        while let sample = decoded.copyNextSampleBuffer() {
            let time = sample.presentationTimeStamp.seconds
            let layers = try await provider.layers(track: track, projectURL: project, time: time, allowMissingImages: false)
            let commands = try canvas.renderer.encode(visuals: layers, features: features, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: time, target: canvas.target, video: true)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commands.addCompletedHandler { _ in continuation.resume() }
                commands.commit()
            }
            XCTAssertEqual(commands.status, .completed)
            let expected = canvas.pixel(960, 540)
            let buffer = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let offset = 540 * CVPixelBufferGetBytesPerRow(buffer) + 960 * 4
            for channel in 0..<3 { XCTAssertEqual(Double(base[offset + channel]), Double(expected[channel]), accuracy: 16) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            count += 1
        }
        XCTAssertEqual(count, 12)
        XCTAssertEqual(reader.status, .completed)
    }

    func testMixedSpineStillVideoAndEmptySources() async throws {
        let (directory, skeleton, atlas) = try SpineTestFixtures.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (descriptor, _) = try await SpinePoseProvider().inspect(skeleton: skeleton, atlas: atlas)
        let movie = directory.appendingPathComponent("source.mov")
        try await VideoTestFixtures.makeVideo(movie, codec: .h264, times: [0, 0.1, 0.2, 0.3], end: 1)
        var track = VisualTrack()
        let spineID = track.register(url: skeleton, projectURL: project, kind: .spine(descriptor))
        let imageID = track.register(url: directory.appendingPathComponent("page.png"), projectURL: project)
        let videoID = track.register(url: movie, projectURL: project, kind: .video(duration: 1))
        let sources: [(UUID?, VisualContent)] = [(spineID, .spine(SpinePlayback(animationName: "move"))), (imageID, .still),
                                               (videoID, .video(sourceIn: 0)), (nil, .still)]
        let provider = VisualFrameProvider(), canvas = try EffectTestCanvas(scale: 0.25)
        for index in 0..<sources.count {
            let a = sources[index], b = sources[(index + 1) % sources.count]
            track.layers[0].clips = [VisualClip(assetID: a.0, start: 0, end: 0.6, content: a.1),
                                     VisualClip(assetID: b.0, start: 0.2, end: 0.8, content: b.1)]
            try track.validate(duration: 1)
            let layers = try await provider.layers(track: track, projectURL: project, time: 0.4, allowMissingImages: false)
            XCTAssertEqual(layers.count, 2)
            XCTAssertEqual(Set(layers.map(\.layerID)), [track.layers[0].id])
            let commands = try canvas.renderer.encode(visuals: layers, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: 0.4, target: canvas.target, video: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commands.addCompletedHandler { _ in continuation.resume() }; commands.commit()
            }
            XCTAssertEqual(commands.status, .completed)
        }
    }

    func testTwoVideoClipsUseIndependentSourceClocks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("video.mov")
        try await VideoTestFixtures.makeVideo(url, codec: .h264, times: [0, 0.1, 0.35, 0.8, 1.1], end: 1.5)
        var track = VisualTrack()
        let id = track.register(url: url, projectURL: project, kind: .video(duration: 1.5))
        let a = VisualClip(assetID: id, start: 0, end: 1, content: .video(sourceIn: 0))
        let b = VisualClip(assetID: id, start: 0.5, end: 1.2, content: .video(sourceIn: 0.1))
        track.layers[0].clips = [a, b]; try track.validate(duration: 2)
        let provider = VisualFrameProvider()
        for (time, expected) in [(0.9, [0.8, 0.35]), (0.55, [0.35, 0.1])] {
            let layers = try await provider.layers(track: track, projectURL: project, time: time, allowMissingImages: false)
            XCTAssertEqual(layers.count, 2)
            for (clipID, pts) in zip([a.id, b.id], expected) {
                XCTAssertEqual(try XCTUnwrap(layers.first { $0.clip.id == clipID }?.frame?.presentationTime).seconds, pts, accuracy: 0.001)
            }
        }
    }
}
