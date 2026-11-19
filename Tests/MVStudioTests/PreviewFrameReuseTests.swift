import AVFoundation
import AppKit
import XCTest
@testable import MVStudio

final class PreviewFrameReuseTests: XCTestCase {
    func testEditsReuseSourceAndApplyLatestClipAndSlot() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let original = VisualClip(start: 0, end: 5)
        let layer = VisualRenderLayer(clip: original, image: image)
        var track = VisualTrack()
        track.layers[0].clips = [original]
        var edited = original
        edited.end = 8
        edited.fixedValues[.opacity] = 35
        edited.effects = ImageEffects()
        edited.effects?.blur = .init()
        track = try track.updating(edited, layerID: track.layers[2].id, duration: 10)
        let result = try XCTUnwrap(PreviewFrameReuse.stills([layer], track: track, time: 2))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].clip, edited)
        XCTAssertEqual(result[0].layerID, track.layers[2].id)
        XCTAssertTrue(result[0].frame === layer.frame)
        // Repeated edits preserve the exact decoded frame, including empty-clip sources.
        edited.end = 9
        track = try track.updating(edited, layerID: track.layers[2].id, duration: 10)
        XCTAssertTrue(try XCTUnwrap(PreviewFrameReuse.stills(result, track: track, time: 2)).first?.frame === layer.frame)
        XCTAssertEqual(PreviewFrameReuse.stills(result, track: track, time: 9)?.count, 0)
        XCTAssertEqual(PreviewFrameReuse.stills(result, track: VisualTrack(), time: 2)?.count, 0)
    }

    func testNewOrChangedSourcesRequireAcquisition() throws {
        let base = VisualTrack()
        let added = try base.addingEmpty(at: 0, layerID: base.layers[0].id, duration: 10, grid: TimelineSnapGrid(bpm: 120, origin: 0))
        XCTAssertNil(PreviewFrameReuse.stills([], track: added.track, time: 0.5))
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let layer = VisualRenderLayer(clip: added.clip, image: try XCTUnwrap(context.makeImage()))
        var track = added.track
        var clip = added.clip
        clip.assetID = track.register(url: URL(fileURLWithPath: "/tmp/replacement.png"), projectURL: URL(fileURLWithPath: "/tmp/song.mvproject"))
        track = try track.updating(clip, layerID: track.layers[0].id, duration: 10)
        XCTAssertNil(PreviewFrameReuse.stills([layer], track: track, time: 0.5))
        clip.content = .video(sourceIn: 0)
        track.layers[0].clips = [clip]
        XCTAssertNil(PreviewFrameReuse.stills([layer], track: track, time: 0.5))
    }

    @MainActor func testApplicationKeepsLayersDuringEditsAndSeek() async throws {
        let app = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80000)!
        buffer.frameLength = 80000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 80000)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let suite = "UndoTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectStorage(defaults: defaults)
        let projectURL = ProjectStorage.projectURL(for: audio)
        let initial = ProjectFile(audioURL: audio, settings: SceneSettings(), projectURL: projectURL)
        try storage.save(initial, to: projectURL)
        let delegate = AppDelegate(storage: storage)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
            delegate.window.close()
        }
        let editor = delegate.placementEditor
        for _ in 0..<250 {
            if editor.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.duration, 10, accuracy: 0.01)

        func findPreview(_ view: NSView) -> PreviewView? {
            if let preview = view as? PreviewView { return preview }
            return view.subviews.lazy.compactMap { findPreview($0) }.first
        }
        let preview = try XCTUnwrap(findPreview(delegate.window.contentView!))
        let base = VisualTrack()
        let added = try base.addingEmpty(at: 0, layerID: base.layers[0].id, duration: 10, grid: TimelineSnapGrid(bpm: 120, origin: 0))
        editor.visuals.commit(added.track, selectedID: added.clip.id)
        for _ in 0..<250 {
            if !preview.visuals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let source = try XCTUnwrap(preview.visuals.first?.frame)
        editor.visuals.onBeginEdit?()
        XCTAssertEqual(preview.visuals.count, 1)
        for value in 1...30 {
            var clip = added.clip
            clip.end = 4
            clip.fixedValues[.opacity] = Double(value)
            let updated = try added.track.updating(clip, layerID: added.track.layers[1].id, duration: 10)
            editor.visuals.onPreview?(updated)
            XCTAssertEqual(preview.visuals.count, 1, "No empty frame may be published between updates")
            XCTAssertEqual(preview.visuals.first?.clip, clip)
            XCTAssertEqual(preview.visuals.first?.layerID, added.track.layers[1].id)
            XCTAssertTrue(preview.visuals.first?.frame === source)
        }
        editor.visuals.onSeek?(0.5)
        XCTAssertEqual(preview.visuals.count, 1)
        editor.visuals.onPreview?(VisualTrack())
        XCTAssertTrue(preview.visuals.isEmpty)
    }
}
