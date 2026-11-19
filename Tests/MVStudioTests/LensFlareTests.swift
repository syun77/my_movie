import AVFoundation
import AppKit
import XCTest
@testable import MVStudio

final class LensFlareTests: XCTestCase {
    @MainActor func testEditor() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
        editor.load(clip, editable: true)
        editor.onCommit = { clip.effects = $0; editor.load(clip, editable: true) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "レンズフレア"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.lensFlare)
        for parameter in ImageEffects.LensFlare.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.defaultValue)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let toggle = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "visuals.flare.automatic" })
        for state in [NSControl.StateValue.on, .off] {
            toggle.state = state
            XCTAssertTrue(toggle.sendAction(toggle.action, to: toggle.target))
            XCTAssertEqual(clip.effects?.lensFlare?.automaticMotion, state == .on)
            for parameter in [ImageParameter.flareX, .flareY] {
                let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
                XCTAssertEqual(field.isEnabled, state == .off)
            }
        }
    }
    func testAutomaticMotionClockPersistenceAndTrim() throws {
        let flare = ImageEffects.LensFlare(automaticMotion: true)
        let t = 1.25
        let position = flare.sourcePosition(at: t)
        XCTAssertEqual(position.x, 0.5 + sin(t) * 0.5 * 1080 / 1920, accuracy: 1e-12)
        XCTAssertEqual(position.y, 0.5 - sin(t * 0.913) * 0.5, accuracy: 1e-12)
        var clip = VisualClip(assetID: nil, start: 0, end: 3, audioModulations: [:], effects: ImageEffects(lensFlare: flare))
        clip.trimStart(to: 0.5)
        XCTAssertEqual(clip.effects?.lensFlare?.sourcePosition(at: t - 0.5), position)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        let old = Data(#"{"isEnabled":true,"x":1440,"y":270,"size":100,"intensity":100}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ImageEffects.LensFlare.self, from: old).automaticMotion)
    }

    func testAutomaticRenderingAndSeek() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(lensFlare: .init(automaticMotion: true))
        func samples() -> [[UInt8]] { stride(from: 10, to: 270, by: 25).flatMap { y in stride(from: 10, to: 480, by: 25).map { canvas.pixel($0, y) } } }
        try canvas.draw([(clip, 1)], time: 0.5)
        let first = samples()
        try canvas.draw([(clip, 1)], time: 1.5)
        XCTAssertNotEqual(first, samples())
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(first, samples())
        clip.trimStart(to: 0.25)
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(first, samples())
    }

    func testMP4Output() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 14400))
        buffer.frameLength = 14400
        for i in 0..<14400 { buffer.floatChannelData![0][i] = Float(sin(Double(i) / 48000 * 440 * 2 * .pi)) * 0.1 }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let features = try AudioAnalyzer.analyze(url: audio)
        var track = VisualTrack()
        let focus = ImageEffects.LensFlare(automaticMotion: true)
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(lensFlare: focus))]
        let output = directory.appendingPathComponent("lens-flare.mp4")
        try await VideoExporter.export(visuals: track, projectURL: ProjectStorage.projectURL(for: audio), audioURL: audio,
                                       features: features, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(),
                                       destination: output, cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: videos[0], outputSettings: nil)
        reader.add(frames); XCTAssertTrue(reader.startReading())
        var index: Int64 = 0
        while let sample = frames.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(index) / 30, accuracy: 1e-6)
            index += 1
        }
        XCTAssertEqual(index, Int64(ceil(features.duration * 30))); XCTAssertEqual(reader.status, .completed)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(value: 3, timescale: 30), actualTime: nil)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                            space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Flip Core Graphics so sample coordinates use the application's top-left origin.
        context.translateBy(x: 0, y: 1080); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let colored = (0..<(1920 * 1080)).filter { bytes[$0 * 4] > 80 && bytes[$0 * 4 + 1] > 50 }
        XCTAssertGreaterThan(colored.count, 1000, "フレアがMP4にも描画される")
    }


    func testPersistenceAndAutomation() throws {
        var clip = VisualClip(assetID: nil, start: 0, end: 3, audioModulations: [:], effects: ImageEffects(lensFlare: .init()))
        for parameter in ImageEffects.LensFlare.parameters {
            let definition = try XCTUnwrap(parameter.effect)
            _ = clip.setKey(parameter, at: 0, value: definition.range.lowerBound)
            _ = clip.setKey(parameter, at: 2, value: definition.range.upperBound)
            XCTAssertEqual(definition.read(try XCTUnwrap(clip.evaluatedEffects(at: 1))), (definition.range.lowerBound + definition.range.upperBound) / 2)
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        XCTAssertTrue(clip.effects!.isValid)
        clip.effects?.lensFlare?.size = .nan
        XCTAssertFalse(clip.effects!.isValid)
    }
    func testRenderingPositionOpacityAndSeek() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(lensFlare: .init())
        func sample() -> [[UInt8]] { stride(from: 10, to: 270, by: 20).flatMap { y in stride(from: 10, to: 480, by: 20).map { canvas.pixel($0, y) } } }
        try canvas.draw([(clip, 1)])
        let first = sample()
        XCTAssertTrue(first.contains { $0[0] > 50 })
        try canvas.save("/tmp/my-movie-lens-flare-preview.png")
        clip.effects?.lensFlare?.x = 480
        try canvas.draw([(clip, 1)])
        XCTAssertNotEqual(first, sample())
        clip.effects?.lensFlare?.x = 1440
        try canvas.draw([(clip, 1)], time: 1.5)
        XCTAssertEqual(first, sample())
        clip.effects?.lensFlare?.intensity = 0
        try canvas.draw([(clip, 1)])
        let hidden = sample()
        clip.effects = nil
        try canvas.draw([(clip, 1)])
        XCTAssertEqual(hidden, sample())
    }
}
