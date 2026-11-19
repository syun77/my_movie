import AppKit
import AVFoundation
import Metal
import XCTest
@testable import MVStudio

final class StraightLinesTests: XCTestCase {
    func testGeometryClockTrimAndValidation() throws {
        let effect = ImageEffects.StraightLines(seed: 42)
        let original = effect.lines(at: 1.5)
        XCTAssertFalse(original.isEmpty)
        XCTAssertEqual(original, effect.lines(at: 1.5))
        XCTAssertNotEqual(original, effect.lines(at: 1.6))
        var still = effect; still.speed = 0
        XCTAssertEqual(still.lines(at: -5), still.lines(at: 100))
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(straightLines: effect))
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.straightLines?.lines(at: 0.5), original)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        for angle in [-180.0, -90, -45, 0, 45, 90, 180] {
            var angled = effect; angled.angle = angle
            for line in angled.lines(at: -100) {
                XCTAssertEqual(Double(line.axis.z), cos(angle * .pi / 180), accuracy: 1e-6)
                XCTAssertEqual(Double(line.axis.w), sin(angle * .pi / 180), accuracy: 1e-6)
                XCTAssertGreaterThanOrEqual(line.shape.z, 0)
                XCTAssertGreaterThanOrEqual(line.shape.y, 0.25)
            }
        }
        var invalid = effect; invalid.count = 0
        XCTAssertTrue(invalid.lines(at: 0).isEmpty)
        invalid.count = 1.5; XCTAssertFalse(invalid.isValid)
        invalid = effect; invalid.phaseOffset = .infinity; XCTAssertFalse(invalid.isValid)
        invalid = effect; invalid.thickness = .nan; XCTAssertFalse(invalid.isValid)
        var longer = effect; longer.count = 300
        let first = effect.lines(at: 0)
        XCTAssertEqual(Array(longer.lines(at: 0).prefix(first.count)), first)
        XCTAssertTrue(effect.lines(at: 1e200).allSatisfy { $0.axis.x.isFinite })
    }

    func testAutomationMusicPersistenceAndDeletion() throws {
        var clip = VisualClip(assetID: nil, start: 0, end: 4, audioModulations: [:], effects: ImageEffects(straightLines: .init(seed: 42)))
        for parameter in ImageEffects.StraightLines.parameters {
            let range = parameter.defaultRange
            _ = clip.setKey(parameter, at: 0, value: range.lowerBound)
            _ = clip.setKey(parameter, at: 2, value: range.upperBound)
            let value = try XCTUnwrap(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 1))))
            XCTAssertEqual(value, (range.lowerBound + range.upperBound) / 2, accuracy: 1e-6)
        }
        var track = VisualTrack(); track.layers[0].clips = [clip]
        try track.validate(duration: 4)
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/song.wav"), visuals: track, settings: SceneSettings(), projectURL: URL(fileURLWithPath: "/tmp/test.mvproject"))
        let restored = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        try restored.validate(); XCTAssertEqual(restored.visuals, track)
        var synced = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:], effects: ImageEffects(straightLines: .init(opacity: 0, seed: 42)))
        synced.audioModulations[.straightOpacity] = AudioModulation(source: .beat, amount: 100)
        XCTAssertEqual(synced.evaluatedEffects(at: 0)?.straightLines?.opacity, 100)
        XCTAssertEqual(synced.evaluatedEffects(at: 0.3)?.straightLines?.opacity, 0)
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{\"nodes\":[],\"isBypassed\":false}".utf8)).straightLines)
    }

    func testVariationPreservesColorAndRevealsBackground() throws {
        let canvas = try EffectTestCanvas()
        var background = canvas.clip
        background.effects = ImageEffects(solidBackground: .init(color: .white))
        var clip = canvas.clip; clip.id = UUID()
        for color in [RGBColor.black, RGBColor(red: 1, green: 0, blue: 0)] {
            for opacity in [100.0, 50] {
                let effect = ImageEffects.StraightLines(count: 1, length: 3840, thickness: 20, speed: 0,
                    lengthVariation: 0, thicknessVariation: 0, toneVariation: 100, fade: 0, glow: 0,
                    opacity: 100, color: color, seed: 42)
                let line = try XCTUnwrap(effect.lines(at: 0).first)
                let x = Int(min(1800, max(120, line.axis.x)))
                let y = Int(line.axis.y)
                clip.effects = ImageEffects(straightLines: effect)
                clip.fixedValues[.opacity] = opacity
                try canvas.draw([(background, 1), (clip, 2)])
                let alpha = Double(line.opacityScale.x) * opacity / 100
                let expected = 255 * (1.055 * pow(1 - alpha, 1 / 2.4) - 0.055)
                let pixel = canvas.pixel(x, y)
                XCTAssertEqual(Double(pixel[1]), expected, accuracy: 3)
                XCTAssertEqual(Double(pixel[2]), color.red == 1 ? 255 : expected, accuracy: 3)
                XCTAssertGreaterThan(pixel[1], 0)
            }
        }
    }

    func testRenderedCoreGlowMaskAndScale() throws {
        let canvas = try EffectTestCanvas()
        let half = try EffectTestCanvas(scale: 0.5)
        var clip = canvas.clip
        let effect = ImageEffects.StraightLines(length: 3840, thickness: 10, speed: 0, lengthVariation: 0, thicknessVariation: 0, toneVariation: 0, fade: 0, glow: 0, opacity: 100, color: .white, seed: 42)
        clip.effects = ImageEffects(solidBackground: .init(color: .black), straightLines: effect)
        let line = try XCTUnwrap(effect.lines(at: 0).first { abs($0.axis.y - 540) < 500 && abs($0.axis.x - 960) < 900 })
        let y = Int(line.axis.y)
        let x = Int(line.axis.x)
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(x, y)[0], 250)
        try half.draw([(clip, 1)])
        XCTAssertGreaterThan(half.pixel(x / 2, y / 2)[0], 240)
        let samples = stride(from: 10, to: 1070, by: 7).map { canvas.pixel(x, $0)[0] }
        clip.effects?.straightLines?.glow = 200
        try canvas.draw([(clip, 1)])
        let glowing = stride(from: 10, to: 1070, by: 7).map { canvas.pixel(x, $0)[0] }
        XCTAssertTrue(zip(samples, glowing).contains { Int($0.1) > Int($0.0) + 5 })
        try canvas.draw([])
        let background = canvas.pixel(x, y)[0]
        clip.fixedValues[.opacity] = 0
        try canvas.draw([(clip, 1)])
        XCTAssertEqual(canvas.pixel(x, y)[0], background)
        clip.fixedValues[.opacity] = 100
        var owner = canvas.clip; owner.id = UUID()
        owner.effects = ImageEffects(belowMask: .init(geometry: ShapeGeometry(width: 0)))
        try canvas.draw([(clip, 1), (owner, 2)])
        XCTAssertEqual(canvas.pixel(x, y)[0], background)
        clip.effects = ImageEffects(straightLines: .init(seed: 42))
        try canvas.draw([(clip, 1)], time: 0.5)
        try canvas.save("/tmp/my-movie-straight-default.png")
        clip.effects?.straightLines?.count = 300
        var top = clip; top.id = UUID()
        try canvas.draw([(clip, 1), (top, 2)], time: 1.5)
        print("STRAIGHT_RENDER gpu_ms=\(canvas.lastGPUMS)")
    }

    @MainActor
    func testEditorAdditionColorFieldsAndRemoval() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
        func load() { editor.load(clip, editable: true) }
        load()
        editor.onCommit = { clip.effects = $0; load() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let add = try XCTUnwrap(all(editor).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "直線効果線"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.straightLines)
        XCTAssertFalse(try XCTUnwrap(add.menu?.effectItem(titled: item.title + "（追加済み）")).isEnabled)
        let fields = all(editor).compactMap { $0 as? DragValueField }
        for parameter in ImageEffects.StraightLines.parameters {
            let field = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let length = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.straightLength" })
        XCTAssertEqual(length.doubleValue, 80)
        length.stringValue = "100"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: length))
        XCTAssertEqual(clip.effects?.straightLines?.length, 1000)
        XCTAssertTrue(length.onDragStart?() == true)
        length.onDragChange?(3)
        length.onDragEnd?()
        XCTAssertEqual(clip.effects?.straightLines?.length, 1030)
        XCTAssertTrue(length.onDragStart?() == true)
        length.onDragChange?(20)
        XCTAssertTrue(length.cancelNumberDrag())
        XCTAssertEqual(clip.effects?.straightLines?.length, 1030)
        XCTAssertEqual(length.doubleValue, 103)
        length.onReset?()
        XCTAssertEqual(clip.effects?.straightLines?.length, 800)
        XCTAssertEqual(length.doubleValue, 80)
        let speed = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.straightSpeed" })
        XCTAssertEqual(speed.doubleValue, 160)
        speed.stringValue = "200"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: speed))
        XCTAssertEqual(clip.effects?.straightLines?.speed, 2000)
        XCTAssertTrue(speed.onDragStart?() == true)
        speed.onDragChange?(3)
        speed.onDragEnd?()
        XCTAssertEqual(clip.effects?.straightLines?.speed, 2030)
        XCTAssertTrue(speed.onDragStart?() == true)
        speed.onDragChange?(20)
        XCTAssertTrue(speed.cancelNumberDrag())
        XCTAssertEqual(clip.effects?.straightLines?.speed, 2030)
        XCTAssertEqual(speed.doubleValue, 203)
        speed.onReset?()
        XCTAssertEqual(clip.effects?.straightLines?.speed, 1600)
        XCTAssertEqual(speed.doubleValue, 160)
        let color = try XCTUnwrap(all(editor).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.straightColor" })
        color.activate(true)
        NSColorPanel.shared.color = .red
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(clip.effects?.straightLines?.color, RGBColor(red: 1, green: 0, blue: 0))
        color.deactivate(); NSColorPanel.shared.orderOut(nil)
        let shuffle = try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "visuals.effects.straightShuffle" })
        let seed = clip.effects?.straightLines?.seed
        XCTAssertTrue(shuffle.sendAction(shuffle.action, to: shuffle.target))
        XCTAssertNotEqual(clip.effects?.straightLines?.seed, seed)
        let remove = try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.straightLines)
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
        let focus = ImageEffects.StraightLines(count: 40, length: 3840, thickness: 30, speed: 0, lengthVariation: 0, thicknessVariation: 0, toneVariation: 0, fade: 0, glow: 0, opacity: 100, color: .white, seed: 42)
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(straightLines: focus))]
        let output = directory.appendingPathComponent("focus.mp4")
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let line = try XCTUnwrap(focus.lines(at: 0).first { abs($0.axis.y - 540) < 520 && abs($0.axis.x - 960) < 900 })
        let y = Int(line.axis.y)
        let x = Int(line.axis.x)
        XCTAssertGreaterThan(bytes[(y * 1920 + x) * 4], 230)
    }

}
