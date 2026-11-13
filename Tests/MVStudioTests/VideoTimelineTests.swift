import AppKit
import AVFoundation
import CoreImage
import Metal
import XCTest
@testable import MVStudio

final class VideoTimelineTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/video-test/song.wav.mvproject")

    @MainActor func testSourceMappingTrimBoundariesAndPersistence() throws {
        var track = VisualTrack()
        let id = track.register(url: URL(fileURLWithPath: "/tmp/video-test/clip.mov"), projectURL: project, kind: .video(duration: 8))
        let result = try track.adding(assetID: id, at: 10, slot: 1, duration: 30, grid: TimelineSnapGrid())
        track = result.track
        XCTAssertEqual(result.clip.end, 18)
        XCTAssertTrue(result.clip.audioModulations.isEmpty)
        let trimmed = try track.dragging(id: result.clip.id, part: .start, delta: 3, duration: 30, grid: TimelineSnapGrid())
        let clip = try XCTUnwrap(trimmed.clip(result.clip.id))
        XCTAssertEqual(clip.content.sourceIn, 3)
        XCTAssertEqual(clip.end, 18)
        let moved = try trimmed.dragging(id: clip.id, part: .move, delta: 7, duration: 30, grid: TimelineSnapGrid())
        XCTAssertEqual(moved.clip(clip.id)?.start, 20)
        XCTAssertEqual(moved.clip(clip.id)?.content.sourceIn, 3)
        XCTAssertEqual(try moved.dragging(id: clip.id, part: .end, delta: 5, duration: 30, grid: TimelineSnapGrid()).clip(clip.id)?.end, 25)
        let extended = try trimmed.dragging(id: clip.id, part: .start, delta: -100, duration: 30, grid: TimelineSnapGrid())
        XCTAssertEqual(extended.clip(clip.id)?.start, 10)
        XCTAssertEqual(extended.clip(clip.id)?.content.sourceIn, 0)
        var invalid = clip; invalid.content = .video(sourceIn: 4)
        XCTAssertThrowsError(try trimmed.updating(invalid, slot: 1, duration: 30))
        XCTAssertThrowsError(try trimmed.replacingAsset(id: id, url: URL(fileURLWithPath: "/tmp/short.mov"), projectURL: project, kind: .video(duration: 4)))
        XCTAssertThrowsError(try trimmed.replacingAsset(id: id, url: URL(fileURLWithPath: "/tmp/still.png"), projectURL: project))
        let file = ProjectFile(audioURL: project.deletingPathExtension(), visuals: moved, settings: SceneSettings(), projectURL: project)
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(file))
        try decoded.validate()
        XCTAssertEqual(decoded.version, ProjectFile.currentVersion); XCTAssertEqual(decoded.visuals, moved)
        let history = EditHistory()
        history.reset(EditSnapshot(lyrics: LyricsTrack(), visuals: track, settings: SceneSettings()))
        history.record(EditSnapshot(lyrics: LyricsTrack(), visuals: moved, settings: SceneSettings()))
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertEqual(history.redo()?.visuals, moved)
    }

    @MainActor func testPlaybackSpeedMappingValidationTrimAndStorage() throws {
        var track = VisualTrack()
        let id = track.register(url: URL(fileURLWithPath: "/tmp/video-test/speed.mov"), projectURL: project, kind: .video(duration: 8))
        let clip = VisualClip(assetID: id, start: 10, end: 13, content: .video(sourceIn: 2, speed: 2))
        track.layers[0].clips = [clip]
        try track.validate(duration: 30)
        XCTAssertEqual(clip.sourceTime(at: 11.5), 5)
        XCTAssertEqual(clip.sourceEnd, 8)
        let trimmed = try track.dragging(id: clip.id, part: .start, delta: 1, duration: 30, grid: TimelineSnapGrid())
        XCTAssertEqual(trimmed.clip(clip.id)?.content.sourceIn, 4)
        XCTAssertEqual(trimmed.clip(clip.id)?.content.speed, 2)
        let extended = try trimmed.dragging(id: clip.id, part: .start, delta: -100, duration: 30, grid: TimelineSnapGrid())
        XCTAssertEqual(extended.clip(clip.id)?.start, 9)
        XCTAssertEqual(extended.clip(clip.id)?.content.sourceIn, 0)
        XCTAssertEqual(try track.dragging(id: clip.id, part: .end, delta: 100, duration: 30, grid: TimelineSnapGrid()).clip(clip.id)?.end, 13)
        for speed in [0, -1, 0.09, 16.01, Double.nan, .infinity, 3] {
            var invalid = clip; invalid.content = .video(sourceIn: 2, speed: speed)
            XCTAssertThrowsError(try track.updating(invalid, slot: 1, duration: 30))
        }
        var slow = clip; slow.content = .video(sourceIn: 2, speed: 0.5); slow.end = 22
        let slowTrack = try track.updating(slow, slot: 1, duration: 30)
        XCTAssertEqual(slow.sourceTime(at: 14), 4)
        XCTAssertEqual(try JSONDecoder().decode(VisualTrack.self, from: JSONEncoder().encode(slowTrack)), slowTrack)
        let legacy = Data(#"{"video":{"sourceIn":2}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(VisualContent.self, from: legacy))
        let history = EditHistory()
        history.reset(EditSnapshot(lyrics: LyricsTrack(), visuals: track, settings: SceneSettings()))
        history.record(EditSnapshot(lyrics: LyricsTrack(), visuals: slowTrack, settings: SceneSettings()))
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertEqual(history.redo()?.visuals, slowTrack)
    }

    func testPlaybackSpeedSelectsSourceFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("speed.mov")
        try await VideoTestFixtures.makeVideo(url, codec: .h264, times: [0, 0.1, 0.35, 0.8, 1.1], end: 1.5)
        var track = VisualTrack()
        let id = track.register(url: url, projectURL: project, kind: .video(duration: 1.5))
        var clip = VisualClip(assetID: id, start: 10, end: 10.7, content: .video(sourceIn: 0.1, speed: 2))
        track.layers[0].clips = [clip]
        let provider = VideoFrameProvider()
        for (time, pts) in [(10.2, 0.35), (10.5, 1.1), (10.01, 0.1)] {
            let layers = try await provider.layers(track: track, projectURL: project, time: time)
            XCTAssertEqual(try XCTUnwrap(layers.first?.frame?.presentationTime).seconds, pts, accuracy: 0.001)
        }
        clip.content = .video(sourceIn: 0.1, speed: 0.5)
        track.layers[0].clips = [clip]
        let layers = try await provider.layers(track: track, projectURL: project, time: 10.6)
        XCTAssertEqual(try XCTUnwrap(layers.first?.frame?.presentationTime).seconds, 0.35, accuracy: 0.001)
    }

    func testReaderSelectsPTSForVFRSeeksAndIndependentPlacements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vfr.mov")
        try await VideoTestFixtures.makeVideo(url, codec: .h264, times: [0, 0.1, 0.35, 0.8, 1.1], end: 1.5, rotated: true)
        let provider = VideoFrameProvider()
        let (kind, _) = try await provider.inspect(url)
        XCTAssertEqual(try XCTUnwrap(kind.videoDuration), 1.5, accuracy: 0.001)
        var track = VisualTrack()
        let id = track.register(url: url, projectURL: project, kind: kind)
        var first = VisualClip(assetID: id, start: 10, end: 11, content: .video(sourceIn: 0), audioModulations: [:])
        let second = VisualClip(assetID: id, start: 10, end: 11, content: .video(sourceIn: 0.4), audioModulations: [:])
        track.layers[0].clips = [first]; track.layers[1].clips = [second]
        let renderer = try MetalSceneRenderer(scale: 0.1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 192, height: 108, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        var renderedRed: [Int] = []
        for (time, pts) in [(10.36, 0.35), (10.05, 0.0), (10.85, 0.8), (10.2, 0.1)] {
            let layers = try await provider.layers(track: track, projectURL: project, time: time)
            XCTAssertEqual(layers.count, 2)
            XCTAssertEqual(layers[0].frame?.width, 48); XCTAssertEqual(layers[0].frame?.height, 64)
            XCTAssertEqual(try XCTUnwrap(layers[0].frame?.presentationTime).seconds, pts, accuracy: 1e-6)
            if time == 10.36 { XCTAssertEqual(try XCTUnwrap(layers[1].frame?.presentationTime).seconds, 0.35, accuracy: 1e-6) }
            let commands = try renderer.encode(visuals: [layers[0]], features: nil, settings: SceneSettings(spectrum: false),
                lyrics: LyricsTrack(), time: time, target: target, video: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commands.addCompletedHandler { _ in continuation.resume() }
                commands.commit()
            }
            XCTAssertEqual(commands.status, .completed)
            var pixel = [UInt8](repeating: 0, count: 4)
            target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(96, 54, 1, 1), mipmapLevel: 0)
            renderedRed.append(Int(pixel[2]))
        }
        XCTAssertGreaterThan(renderedRed[0], renderedRed[1] + 30)
        XCTAssertGreaterThan(renderedRed[2], renderedRed[0] + 20)
        first.content = .video(sourceIn: 0.5); track.layers[0].clips = [first]
        let layers = try await provider.layers(track: track, projectURL: project, time: 10.4)
        XCTAssertEqual(try XCTUnwrap(layers[0].frame?.presentationTime).seconds, 0.8, accuracy: 1e-6)
        let inactive = try await provider.layers(track: track, projectURL: project, time: 11)
        XCTAssertTrue(inactive.isEmpty)
        await provider.invalidate()
    }

    @MainActor func testVideoImportSourceFieldAndClipboard() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.mov")
        try await VideoTestFixtures.makeVideo(url, codec: .hevc, times: [0, 0.5, 1, 1.5, 2], end: 3)
        let editor = PlacementEditor(); _ = editor.view
        editor.duration = 10; editor.currentTime = 1
        editor.visuals.load(VisualTrack(), projectURL: project)
        editor.setAvailable(hasAudio: true, isBusy: false); editor.restoreTab(.visuals)
        editor.visuals.importFile(url, placement: (2, 1))
        for _ in 0..<1000 {
            if !editor.visuals.isProcessing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(editor.visuals.isProcessing)
        let clip = try XCTUnwrap(editor.visuals.track.clips.first)
        XCTAssertEqual(clip.start, 1); XCTAssertEqual(clip.end, 4)
        let field = try XCTUnwrap(DragValueField.fields(in: editor.visuals.view).first { $0.identifier?.rawValue == "visual.sourceIn" })
        let end = try XCTUnwrap(DragValueField.fields(in: editor.visuals.view).first { $0.identifier?.rawValue == "visuals.end" })
        end.stringValue = "3"
        editor.visuals.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
        field.stringValue = "0.5"
        editor.visuals.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(editor.visuals.track.clip(clip.id)?.content.sourceIn, 0.5)
        let speed = try XCTUnwrap(DragValueField.fields(in: editor.visuals.view).first { $0.identifier?.rawValue == "visual.playbackSpeed" })
        XCTAssertFalse(speed.superview!.isHidden)
        speed.stringValue = "0.5"
        editor.visuals.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: speed))
        XCTAssertEqual(editor.visuals.track.clip(clip.id)?.content.speed, 0.5)
        XCTAssertEqual(editor.visuals.track.clip(clip.id)?.end, 5)
        XCTAssertEqual(end.doubleValue, 5)
        speed.frame.size = NSSize(width: 100, height: 26)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: speed.convert(NSPoint(x: 50, y: 13), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(speed.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["x0.25", "x0.5", "x1.0", "x2.0", "x4.0", "x8.0", "x16.0"])
        XCTAssertEqual(menu.items[1].state, .on)
        let quarter = menu.items[0]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quarter.action), to: quarter.target, from: quarter))
        XCTAssertEqual(editor.visuals.track.clip(clip.id)?.content.speed, 0.25)
        let sixteen = menu.items[6]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sixteen.action), to: sixteen.target, from: sixteen))
        XCTAssertEqual(editor.visuals.track.clip(clip.id)?.content.speed, 16)
        XCTAssertEqual(try XCTUnwrap(editor.visuals.track.clip(clip.id)).end, 1.125, accuracy: 1e-9)
        let half = menu.items[1]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(half.action), to: half.target, from: half))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        editor.editClip(.copy, pasteboard: board)
        editor.currentTime = 5
        editor.editClip(.paste, pasteboard: board)
        let copied = try XCTUnwrap(editor.visuals.track.clips.first { $0.id != clip.id })
        XCTAssertEqual(copied.start, 5); XCTAssertEqual(copied.content.sourceIn, 0.5)
        XCTAssertEqual(copied.content.speed, 0.5)
        let beforeRejectedSlowdown = editor.visuals.track
        editor.timeline.onImageSelect?(clip.id, 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quarter.action), to: quarter.target, from: quarter))
        XCTAssertEqual(editor.visuals.track, beforeRejectedSlowdown)
        editor.timeline.onImageSelect?(copied.id, 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quarter.action), to: quarter.target, from: quarter))
        XCTAssertEqual(editor.visuals.track, beforeRejectedSlowdown)


    }

    @MainActor func testTransportPreparesFramesAndSeeksWithMainAudioClock() async throws {
        let app = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("transport.mov")
        try await VideoTestFixtures.makeVideo(movie, codec: .h264, times: [0, 0.1, 0.35, 0.8, 1.1], end: 1.5)
        let audio = directory.appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
        buffer.frameLength = 64000; buffer.floatChannelData![0].initialize(repeating: 0, count: 64000)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let suite = "VideoTransport." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectStorage(defaults: defaults), projectURL = ProjectStorage.projectURL(for: audio)
        var track = VisualTrack()
        let id = track.register(url: movie, projectURL: projectURL, kind: .video(duration: 1.5))
        track.layers[0].clips = [VisualClip(assetID: id, start: 0, end: 1.5, content: .video(sourceIn: 0), audioModulations: [:])]
        try storage.save(ProjectFile(audioURL: audio, visuals: track, settings: SceneSettings(spectrum: false), projectURL: projectURL), to: projectURL)
        let referenceProvider = VideoFrameProvider()
        let referenceEnd = try await referenceProvider.layers(track: track, projectURL: projectURL, time: 0.85)
        let expectedEnd = try redValue(try XCTUnwrap(referenceEnd[0].frame))
        let referenceStart = try await referenceProvider.layers(track: track, projectURL: projectURL, time: 0.05)
        let expectedStart = try redValue(try XCTUnwrap(referenceStart[0].frame))
        let delegate = AppDelegate(storage: storage)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
            delegate.window.close()
        }
        func findPreview(_ view: NSView) -> PreviewView? {
            if let preview = view as? PreviewView { return preview }
            return view.subviews.lazy.compactMap { findPreview($0) }.first
        }
        let preview = try XCTUnwrap(findPreview(delegate.window.contentView!))
        for _ in 0..<500 {
            if delegate.placementEditor.duration > 0, !preview.visuals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(preview.frameFailure); XCTAssertEqual(preview.visuals.count, 1)
        delegate.perform(NSSelectorFromString("togglePlay"))
        try await Task.sleep(for: .milliseconds(350))
        let time = delegate.placementEditor.currentTime
        XCTAssertGreaterThan(time, 0.1)
        XCTAssertEqual(preview.renderedTime, time, accuracy: 0.1)
        delegate.placementEditor.lyrics.onSeek?(0.85)
        for _ in 0..<500 {
            if preview.renderedTime == 0.85, !preview.visuals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.renderedTime, 0.85)
        XCTAssertEqual(try redValue(try XCTUnwrap(preview.visuals.first?.frame)), expectedEnd, accuracy: 6)
        delegate.placementEditor.lyrics.onSeek?(0.05)
        for _ in 0..<500 {
            if preview.renderedTime == 0.05, !preview.visuals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try redValue(try XCTUnwrap(preview.visuals.first?.frame)), expectedStart, accuracy: 6)
        for time in [0.9, 0.1, 1.2, 0.25, 0.4] { delegate.placementEditor.lyrics.onSeek?(time) }
        for _ in 0..<500 {
            if preview.renderedTime == 0.4, !preview.visuals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.renderedTime, 0.4)
        XCTAssertEqual(try XCTUnwrap(preview.visuals.first?.frame?.presentationTime).seconds, 0.35, accuracy: 1e-6)
        delegate.placementEditor.restoreTab(.visuals)
        delegate.window.contentView?.layoutSubtreeIfNeeded()
        let visuals = delegate.placementEditor.visuals
        let clipID = track.clips[0].id
        delegate.placementEditor.timeline.onImageSelect?(clipID, 1)
        let speed = try XCTUnwrap(DragValueField.fields(in: visuals.view).first { $0.identifier?.rawValue == "visual.playbackSpeed" })
        speed.stringValue = "0.5"
        visuals.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: speed))
        for _ in 0..<500 {
            if preview.visuals.first?.clip.content.speed == 0.5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.visuals.first?.clip.content.speed, 0.5)
        XCTAssertEqual(try XCTUnwrap(preview.visuals.first?.frame?.presentationTime).seconds, 0.1, accuracy: 1e-6)
        speed.frame.size = NSSize(width: 100, height: 26)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: speed.convert(NSPoint(x: 50, y: 13), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: delegate.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(speed.menu(for: event))
        let normal = menu.items[2]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(normal.action), to: normal.target, from: normal))
        for _ in 0..<500 {
            if preview.visuals.first?.clip.content.speed == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.visuals.first?.clip.content.speed, 1)
        XCTAssertEqual(try XCTUnwrap(preview.visuals.first?.frame?.presentationTime).seconds, 0.35, accuracy: 1e-6)
        delegate.undoEdit()
        for _ in 0..<500 {
            if preview.visuals.first?.clip.content.speed == 0.5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.visuals.first?.clip.content.speed, 0.5)
        XCTAssertEqual(try XCTUnwrap(preview.visuals.first?.frame?.presentationTime).seconds, 0.1, accuracy: 1e-6)
        delegate.perform(NSSelectorFromString("togglePlay"))
        try await Task.sleep(for: .milliseconds(150))
        let quarter = menu.items[0]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quarter.action), to: quarter.target, from: quarter))
        for _ in 0..<500 {
            if preview.visuals.first?.clip.content.speed == 0.25 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.visuals.first?.clip.content.speed, 0.25)
        XCTAssertFalse(preview.frameFailure)
        let pausedTime = preview.renderedTime
        delegate.perform(NSSelectorFromString("togglePlay"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(preview.renderedTime, pausedTime)
        delegate.placementEditor.lyrics.onSeek?(0.4)
        visuals.commit(track, selectedID: clipID)
        let twice = menu.items[3]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(twice.action), to: twice.target, from: twice))
        for _ in 0..<500 {
            if preview.visuals.first?.clip.content.speed == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.visuals.first?.clip.content.speed, 2)
        XCTAssertEqual(preview.visuals.first?.clip.end, 0.75)
        XCTAssertEqual(preview.visuals.first?.clip.sourceEnd, 1.5)
        let saved = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: projectURL))
        XCTAssertEqual(saved.visuals.clip(clipID)?.content.speed, 2)
        XCTAssertEqual(saved.visuals.clip(clipID)?.end, 0.75)

        XCTAssertEqual(try XCTUnwrap(preview.visuals.first?.frame?.presentationTime).seconds, 0.8, accuracy: 1e-6)
        func findExport(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "MP4を書き出す" { return button }
            return view.subviews.lazy.compactMap { findExport($0) }.first
        }
        let export = try XCTUnwrap(findExport(delegate.window.contentView!))
        XCTAssertTrue(export.isEnabled)
        delegate.placementEditor.visuals.commit(track.removingClip(id: track.clips[0].id))
        XCTAssertTrue(export.isEnabled)
        delegate.undoEdit(); XCTAssertTrue(export.isEnabled)
        delegate.redoEdit(); XCTAssertTrue(export.isEnabled)
    }

    func testThree1080pLayersSequentialDecodeAndBackwardSeek() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("1080.mov")
        try await VideoTestFixtures.makeVideo(url, codec: .h264, times: (0..<60).map { Double($0) / 30 }, end: 2,
                            width: 1920, height: 1080)
        let provider = VideoFrameProvider()
        var track = VisualTrack()
        let id = track.register(url: url, projectURL: project, kind: .video(duration: 2))
        for index in 0..<3 {
            track.layers[index].clips = [VisualClip(assetID: id, start: 0, end: 1.5, content: .video(sourceIn: Double(index) / 10), audioModulations: [:])]
        }
        var samples: [Double] = []
        for frame in 0..<40 {
            let start = Date()
            let layers = try await provider.layers(track: track, projectURL: project, time: Double(frame) / 30)
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(layers.count, 3)
            XCTAssertEqual(layers[0].frame?.width, 1920)
        }
        let ordered = samples.dropFirst().sorted()
        print("VIDEO_3x1080_DECODE median_ms=\(ordered[ordered.count / 2] * 1000) p95_ms=\(ordered[Int(Double(ordered.count - 1) * 0.95)] * 1000)")
        let started = Date()
        _ = try await provider.layers(track: track, projectURL: project, time: 0.2)
        print("VIDEO_3x1080_BACKWARD_SEEK ms=\(Date().timeIntervalSince(started) * 1000)")
    }

    private func redValue(_ frame: VisualFrame) throws -> Int {
        let context = CIContext()
        let image = try XCTUnwrap(context.createCGImage(frame.image, from: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixels.data!.assumingMemoryBound(to: UInt8.self)[0])
    }

}
