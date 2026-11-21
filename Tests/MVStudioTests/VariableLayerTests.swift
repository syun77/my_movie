import AppKit
import AVFoundation
import Metal
import Darwin
import XCTest
@testable import MVStudio

final class VariableLayerTests: XCTestCase {
    private func complete(_ commands: MTLCommandBuffer) async {
        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }
    }
    private let projectURL = URL(fileURLWithPath: "/tmp/layers/song.wav.mvproject")

    private func populated(_ count: Int) throws -> VisualTrack {
        var track = VisualTrack()
        while track.layers.count < count { track = try track.addingLayer(relativeTo: track.layers.last!.id, above: true).track }
        for index in track.layers.indices {
            let color = RGBColor(red: Double(index % 3 == 0 ? 1 : 0), green: Double(index % 3 == 1 ? 1 : 0), blue: Double(index % 3 == 2 ? 1 : 0))
            track.layers[index].clips = [VisualClip(start: 0, end: 0.2, effects: ImageEffects(solidBackground: .init(color: color)))]
        }
        return track
    }
    func testStableIdentityOrderingLocksAndHistory() async throws {
        var track = try populated(6)
        let owner = track.layers[3].id
        let originalOrder = track.layers.map(\.id)
        let clip = track.layers[3].clips[0]
        let added = try track.addingLayer(relativeTo: owner, above: true)
        XCTAssertEqual(added.track.layers[4].id, added.id)
        XCTAssertEqual(added.track.layers[3].clips[0], clip)
        track = try added.track.movingLayer(owner, relativeTo: originalOrder[0], above: false)
        XCTAssertEqual(track.layers.first?.id, owner)
        XCTAssertEqual(track.layer(owner)?.clips, [clip])
        track = try track.editingLayer(owner) { $0.name = "人物"; $0.isLocked = true }
        XCTAssertThrowsError(try track.movingLayer(owner, relativeTo: originalOrder[1], above: true))
        XCTAssertThrowsError(try track.editingLayer(owner) { $0.isVisible = false })
        XCTAssertThrowsError(try track.updating(clip, layerID: originalOrder[1], duration: 1))
        XCTAssertThrowsError(try track.inserting(VisualClip(start: 0.3, end: 0.5), layerID: owner, duration: 1))
        XCTAssertThrowsError(try track.removingLayer(owner))
        let locked = track
        track = try track.editingLayer(owner) { $0.isLocked = false }
        track = try track.editingLayer(owner) { $0.isVisible = false }
        XCTAssertFalse(track.active(at: 0.1).contains { $0.id == clip.id })
        try track.validate()
        let unlocked = track
        await MainActor.run {
            let history = EditHistory()
            history.reset(EditSnapshot(visuals: locked))
            history.record(EditSnapshot(visuals: unlocked))
            XCTAssertEqual(history.undo()?.visuals, locked)
            XCTAssertEqual(history.redo()?.visuals, unlocked)
        }
        var one = VisualTrack(); one.layers = [one.layers[0]]
        XCTAssertThrowsError(try one.removingLayer(one.layers[0].id))
        var maximum = try populated(VisualTrack.maximumLayers)
        XCTAssertThrowsError(try maximum.addingLayer(relativeTo: maximum.layers[0].id, above: true))
        maximum.layers.append(VisualLayer(name: "超過")); XCTAssertThrowsError(try maximum.validate())
    }
    func testLockedAssetMutationsAndInvalidNames() throws {
        var track = try populated(4)
        let asset = track.register(url: URL(fileURLWithPath: "/tmp/shared.png"), projectURL: projectURL)
        track.layers[1].clips[0].assetID = asset
        track.layers[1].isLocked = true
        XCTAssertThrowsError(try track.removingAsset(id: asset, includingPlacements: true))
        XCTAssertThrowsError(try track.replacingAsset(id: asset, url: URL(fileURLWithPath: "/tmp/new.png"), projectURL: projectURL))
        let id = track.layers[0].id
        for name in ["", "余白 ", "改\n行", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try track.editingLayer(id) { $0.name = name })
        }
        let moved = try track.movingLayer(id, relativeTo: track.layers[3].id, above: true)
        XCTAssertEqual(moved.layer(track.layers[1].id), track.layers[1])
    }
    func testRoundTripAndHeightStayWithLayer() throws {
        var track = try populated(5)
        let id = track.layers[2].id
        var heights = TimelineHeights(); heights[.visual(id)] = 83; heights[.automation(id, .x)] = 45
        track = try track.movingLayer(id, relativeTo: track.layers.last!.id, above: true)
        track = try track.editingLayer(id) { $0.name = "前景"; $0.isVisible = false; $0.isLocked = true }
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/layers/song.wav"), visuals: track, settings: SceneSettings(), timelineHeights: heights, projectURL: projectURL)
        let result = try ProjectMigrator.read(JSONEncoder().encode(project), at: projectURL).project
        XCTAssertEqual(result.visuals, track)
        XCTAssertEqual(result.timelineHeights?[.visual(id)], 83)
        XCTAssertEqual(result.timelineHeights?[.automation(id, .x)], 45)
        let json = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        XCTAssertFalse(json.contains("\"slot\""))
    }
    func testHiddenMissingAssetAndExplicitMaskAdjacency() async throws {
        var track = try populated(4)
        let subject = track.layers[1].id, owner = track.layers[2].id
        track.layers[2].clips[0].effects = ImageEffects(belowMask: .init())
        XCTAssertEqual(track.renderPlacement(for: track.layers[1].clips[0].id)?.maskOwner, owner)
        let added = try track.addingLayer(relativeTo: subject, above: true)
        track = added.track
        XCTAssertEqual(track.renderPlacement(for: track.layer(subject)!.clips[0].id)?.maskOwner, added.id)
        let missing = track.register(url: URL(fileURLWithPath: "/missing/hidden.mov"), projectURL: projectURL, kind: .video(duration: 1))
        track.layers[0].clips[0].assetID = missing; track.layers[0].clips[0].content = .video(sourceIn: 0)
        track.layers[0].isVisible = false
        try track.validate()
        try await VisualAssetLoader().validateUsed(track: track, projectURL: projectURL)
        let provider = VisualFrameProvider()
        let frames = try await provider.layers(track: track, projectURL: projectURL, time: 0.1, allowMissingImages: false)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.first?.maskOwnerID, added.id)
        let hidden = track.layers[0].id
        track = try track.editingLayer(hidden) { $0.isVisible = true }
        do { try await VisualAssetLoader().validateUsed(track: track, projectURL: projectURL); XCTFail("再表示した欠損動画は拒否") } catch { }
    }
    @MainActor func testUnlockedLockRendersGrayAndLockedLockKeepsColor() throws {
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        var track = try populated(3)
        track.layers[1].isLocked = true
        timeline.visuals = track; timeline.visualMode = true
        let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
        timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my-movie-lock-gray.png"))
        let scale = Double(bitmap.pixelsWide) / timeline.bounds.width
        func coloredPixels(y: Int) -> (bright: Int, colored: Int) {
            var bright = 0, colored = 0
            for yy in y..<(y + 17) { for x in 47..<68 {
                let color = bitmap.colorAt(x: Int(Double(x) * scale), y: Int(Double(yy) * scale))!.usingColorSpace(.sRGB)!
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.max()! > 0.4 {
                    bright += 1
                    if channels.max()! - channels.min()! > 0.08 { colored += 1 }
                }
            } }
            return (bright, colored)
        }
        let unlocked = coloredPixels(y: 63), locked = coloredPixels(y: 109)
        XCTAssertGreaterThan(unlocked.bright, 10)
        XCTAssertEqual(unlocked.colored, 0)
        XCTAssertGreaterThan(locked.colored, 10)
    }

    @MainActor func testLayerDragFloatsVisibleGroupAndClearsOnCancelAndDrop() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: timeline.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = timeline; defer { window.close() }
        timeline.visuals = try populated(3); timeline.visualMode = true; timeline.isEnabled = true
        timeline.duration = 1; timeline.visibleSpan = 1; timeline.currentTime = 0.1
        let original = timeline.visuals
        var commits = 0
        timeline.onLayerCommit = { value, _ in commits += 1; timeline.visuals = value }
        func event(_ type: NSEvent.EventType, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(NSPoint(x: 10, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func render(_ path: String) throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return bitmap
        }
        let normal = try render("/tmp/my-movie-layer-drag-before.png")
        timeline.mouseDown(with: event(.leftMouseDown, 70))
        timeline.mouseDragged(with: event(.leftMouseDragged, 72))
        XCTAssertNil(timeline.layerDragPresentation)
        timeline.mouseDragged(with: event(.leftMouseDragged, 260))
        let presentation = try XCTUnwrap(timeline.layerDragPresentation)
        XCTAssertEqual(presentation.floatingRect.minY, 238, accuracy: 0.01)
        XCTAssertEqual(presentation.floatingRect.height, 46)
        let dragging = try render("/tmp/my-movie-layer-drag-floating.png")
        // The floating header must visibly reproduce the grabbed header over the empty viewport.
        let scale = Double(normal.pixelsWide) / timeline.bounds.width
        var beforeInk = 0.0, floatingInk = 0.0, sourceInk = 0.0
        for y in 58..<84 { for x in 72..<165 {
            func brightness(_ image: NSBitmapImageRep, _ y: Int) -> Double {
                image.colorAt(x: Int(Double(x) * scale), y: Int(Double(y) * scale))!.usingColorSpace(.sRGB)!.redComponent
            }
            beforeInk += max(0, brightness(normal, y) - 0.15)
            sourceInk += max(0, brightness(dragging, y) - 0.15)
            floatingInk += max(0, brightness(dragging, y + 190) - 0.15)
        } }
        XCTAssertGreaterThan(beforeInk, 10)
        XCTAssertLessThan(sourceInk, beforeInk * 0.8)
        XCTAssertGreaterThan(floatingInk, beforeInk * 0.6)
        XCTAssertLessThan(floatingInk, beforeInk)
        timeline.cancelDrag()
        XCTAssertNil(timeline.layerDragPresentation); XCTAssertEqual(timeline.visuals, original); XCTAssertEqual(commits, 0)
        timeline.mouseDown(with: event(.leftMouseDown, 70))
        timeline.mouseDragged(with: event(.leftMouseDragged, 150))
        XCTAssertNotNil(timeline.layerDragPresentation)
        timeline.mouseUp(with: event(.leftMouseUp, 150))
        XCTAssertNil(timeline.layerDragPresentation); XCTAssertEqual(commits, 1)
        XCTAssertEqual(timeline.currentTime, 0.1)
    }

    @MainActor func testHeaderAddDragCancelRenameVisibilityAndLock() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 450))
        let editor = VisualEditor(); _ = editor.view
        let window = NSWindow(contentRect: timeline.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = timeline; defer { window.close() }
        editor.timeline = timeline
        editor.duration = 1; editor.load(try populated(5), projectURL: projectURL); editor.setAvailable(true)
        timeline.visualMode = true; timeline.duration = 1; timeline.currentTime = 0.1
        let original = editor.track
        let top = original.layers.last!.id
        var commits = 0; editor.onChange = { _ in commits += 1 }
        timeline.onImagePreview = { _ in }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        timeline.heights[.visual(top)] = 60
        timeline.mouseDown(with: event(.leftMouseDown, 10, 70))
        timeline.mouseDragged(with: event(.leftMouseDragged, 10, 230))
        XCTAssertNotEqual(timeline.visuals.layers.map(\.id), original.layers.map(\.id))
        timeline.cancelDrag(); XCTAssertEqual(editor.track, original); XCTAssertEqual(timeline.visuals, original); XCTAssertEqual(commits, 0)
        timeline.mouseDown(with: event(.leftMouseDown, 10, 70))
        timeline.mouseDragged(with: event(.leftMouseDragged, 10, 230))
        timeline.mouseUp(with: event(.leftMouseUp, 10, 230))
        XCTAssertEqual(commits, 1); XCTAssertEqual(editor.track.layer(top)?.clips, original.layer(top)?.clips)
        XCTAssertEqual(timeline.heights[.visual(top)], 60)
        editor.performLayerAction(top, .lock)
        XCTAssertTrue(editor.track.layer(top)!.isLocked)
        editor.performLayerAction(top, .visibility)
        XCTAssertTrue(editor.track.layer(top)!.isVisible)
        editor.performLayerAction(top, .lock)
        editor.performLayerAction(top, .visibility)
        XCTAssertFalse(editor.track.layer(top)!.isVisible)
        editor.performLayerAction(top, .add(above: true))
        XCTAssertEqual(editor.track.layers.count, 6)
        XCTAssertEqual(timeline.currentTime, 0.1)
        timeline.beginLayerRename(timeline.selectedLayerID)
        let name = try XCTUnwrap(timeline.subviews.compactMap { $0 as? NSTextField }.first)
        name.stringValue = "装飾"
        NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: name)
        XCTAssertEqual(editor.track.layer(timeline.selectedLayerID)?.name, "装飾")
        let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
        timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my-movie-variable-layers.png"))
    }
    func testManyLayerCompositionAndPerformance() async throws {
        let provider = VisualFrameProvider()
        let canvas = try EffectTestCanvas()
        for count in [10, 20, 50] {
            var track = try populated(count)
            track.layers[count - 1].clips[0].effects = ImageEffects(solidBackground: .init(color: .init(red: 1, green: 0, blue: 0)))
            let layers = try await provider.layers(track: track, projectURL: projectURL, time: 0.1, allowMissingImages: false)
            var times: [Double] = []
            for _ in 0..<12 {
                let commands = try canvas.renderer.encode(visuals: layers, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: 0.1, target: canvas.target, video: false)
                await complete(commands); XCTAssertEqual(commands.status, .completed)
                times.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            }
            XCTAssertGreaterThan(canvas.pixel(960, 540)[2], 245)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("VariableLayers \(count): GPU p95 \(times.sorted()[10])ms max \(times.max()!)ms peakRSS \(Double(usage.ru_maxrss) / 1048576)MiB")
            if count == 20 {
                for index in 0..<3 { track.layers[index].clips[0].effects?.radialBlur = .init(strength: 15) }
                let heavy = try await provider.layers(track: track, projectURL: projectURL, time: 0.1, allowMissingImages: false)
                let commands = try canvas.renderer.encode(visuals: heavy, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: 0.1, target: canvas.target, video: false)
                await complete(commands)
                print("VariableLayers 20+3blur: GPU \((commands.gpuEndTime - commands.gpuStartTime) * 1000)ms")
            }
            track = try track.movingLayer(track.layers[0].id, relativeTo: track.layers.last!.id, above: true)
            let updated = try XCTUnwrap(PreviewFrameReuse.stills(layers, track: track, time: 0.1))
            XCTAssertEqual(updated.map(\.layerID), track.layers.map(\.id))
        }
        await provider.invalidate()
    }
    func testMixedVideoSpineAndImagesBeyondThreeLayers() async throws {
        let (directory, skeleton, atlas) = try SpineTestFixtures.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("clip.mov")
        try await VideoTestFixtures.makeVideo(video, codec: .h264, times: [0, 0.1], end: 0.2)
        let project = directory.appendingPathComponent("song.mvproject")
        let spine = SpinePoseProvider()
        let (descriptor, _) = try await spine.inspect(skeleton: skeleton, atlas: atlas)
        var track = try populated(6)
        let movieID = track.register(url: video, projectURL: project, kind: .video(duration: 0.2))
        let spineID = track.register(url: skeleton, projectURL: project, kind: .spine(descriptor))
        track.layers[4].clips[0].assetID = movieID; track.layers[4].clips[0].content = .video(sourceIn: 0)
        track.layers[5].clips[0].assetID = spineID; track.layers[5].clips[0].content = .spine(.init(animationName: "move"))
        let provider = VisualFrameProvider()
        try await provider.validateUsed(track: track, projectURL: project, cancellation: ExportCancellation())
        let frames = try await provider.layers(track: track, projectURL: project, time: 0.1, allowMissingImages: false)
        XCTAssertEqual(frames.map(\.layerID), track.layers.map(\.id))
        XCTAssertNotNil(frames[4].frame?.pixelBuffer)
        if case .spine = frames[5].source {} else { XCTFail("Spine frame missing") }
        let canvas = try EffectTestCanvas()
        let command = try canvas.renderer.encode(visuals: frames, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: 0.1, target: canvas.target, video: false)
        await complete(command); XCTAssertEqual(command.status, .completed)
        track.layers[5].isVisible = false; track.layers[4].isVisible = false
        let hidden = try await provider.layers(track: track, projectURL: project, time: 0.1, allowMissingImages: false)
        XCTAssertEqual(hidden.count, 4)
        await provider.invalidate(); await spine.invalidate()
    }
    func testVariableLayerOrderAndVisibilityMatchAllMP4Frames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
        pcm.frameLength = 9600; pcm.floatChannelData![0].initialize(repeating: 0, count: 9600)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        var track = try populated(6)
        let top = track.layers[0].id
        track = try track.movingLayer(top, relativeTo: track.layers.last!.id, above: true)
        track.layers[4].isVisible = false
        track.layers[5].clips[0].effects?.belowMask = .init(geometry: .init(width: 600, height: 400))
        let project = ProjectStorage.projectURL(for: audio)
        let output = directory.appendingPathComponent("layers.mp4")
        let features = AudioFeatures(duration: 0.2, step: 0.1, frames: [], transientEvents: [TransientBand(): []])
        try await VideoExporter.export(visuals: track, projectURL: project, audioURL: audio, features: features,
                                       settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), destination: output,
                                       cancellation: ExportCancellation(), progress: { _ in })
        let provider = VisualFrameProvider()
        let frames = try await provider.layers(track: track, projectURL: project, time: 0, allowMissingImages: false)
        let canvas = try EffectTestCanvas()
        let commands = try canvas.renderer.encode(visuals: frames, features: features, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: 0, target: canvas.target, video: true)
        await complete(commands)
        let points = [(960, 540), (100, 100), (1500, 800)]
        let expected = points.map { canvas.pixel($0.0, $0.1) }
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: try XCTUnwrap(videos.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = decoded.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            for (i, point) in points.enumerated() {
                let offset = point.1 * CVPixelBufferGetBytesPerRow(buffer) + point.0 * 4
                for channel in 0..<3 { XCTAssertEqual(Double(base[offset + channel]), Double(expected[i][channel]), accuracy: 15) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly); count += 1
        }
        XCTAssertEqual(count, 6); XCTAssertEqual(reader.status, .completed)
        await provider.invalidate()
    }

}
