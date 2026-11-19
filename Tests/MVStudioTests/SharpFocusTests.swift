import AppKit
import AVFoundation
import Metal
import XCTest
@testable import MVStudio

final class SharpFocusTests: XCTestCase {
    func testDeterminismTrimCopyAndValidation() throws {
        let focus = ImageEffects.SharpFocus(seed: 42)
        let first = focus.lines(at: 1.5)
        XCTAssertFalse(first.isEmpty)
        XCTAssertNotEqual(first, focus.lines(at: 1.6))
        XCTAssertEqual(first, focus.lines(at: 1.5))
        var still = focus; still.frequency = 0
        XCTAssertEqual(still.lines(at: -20), still.lines(at: 100))
        still = focus; still.variation = 0; still.toneVariation = 0
        XCTAssertEqual(still.lines(at: -20), still.lines(at: 100))
        var more = focus; more.count = 300
        XCTAssertEqual(Array(more.lines(at: 1.5).prefix(first.count)), first)
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(sharpFocus: focus))
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.sharpFocus?.lines(at: 0.5), first)
        let restored = try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(restored, clip)
        XCTAssertTrue(restored.effects?.isValid == true)
        for (width, height) in [(0.0, 0.0), (0, 360), (640, 0), (3840, 2160)] {
            more.width = width; more.height = height
            XCTAssertTrue(more.lines(at: -100).allSatisfy { $0.axis.x.isFinite && $0.shape.x.isFinite })
        }
        more.width = 3840; more.height = 2160
        XCTAssertTrue(more.lines(at: 0).isEmpty)
        more = focus; more.length = 0
        XCTAssertTrue(more.lines(at: 0).isEmpty)
        more = focus; more.frequency = .nan
        XCTAssertFalse(more.isValid)
        more = focus; more.count = 8.5
        XCTAssertFalse(more.isValid)
        more = focus; more.phaseOffset = .infinity
        XCTAssertFalse(more.isValid)
    }

    func testSharpGeometryAndOpacityVariation() throws {
        var effect = ImageEffects.SharpFocus(variation: 0, tipLength: 0, toneVariation: 0, seed: 42)
        let lines = effect.lines(at: 0)
        XCTAssertEqual(lines.count, 120)
        XCTAssertTrue(lines.allSatisfy { $0.shape.z == 2 && $0.shape.w == 0 && $0.opacityScale.x == 1 })
        effect.toneVariation = 100
        let tones = effect.lines(at: 0).map { $0.opacityScale.x }
        XCTAssertLessThan(try XCTUnwrap(tones.min()), 0.3)
        XCTAssertGreaterThan(try XCTUnwrap(tones.max()), 0.9)
        XCTAssertNotEqual(effect.lines(at: 0), effect.lines(at: 1))
        effect.frequency = 0
        XCTAssertEqual(effect.lines(at: -1), effect.lines(at: 100))
        effect.tipLength = .infinity
        XCTAssertFalse(effect.isValid)
    }

    func testEndpointsStayNearCenterAndReachCanvasEdge() throws {
        for center in [SIMD2(960.0, 540.0), SIMD2(12, 12), SIMD2(1908, 1068)] {
            for variation in [0.0, 75, 100] {
                let effect = ImageEffects.SharpFocus(x: center.x, y: center.y, variation: variation, seed: 42)
                for time in [-1.0, 0, 0.5, 1.5] {
                    let lines = effect.lines(at: time)
                    XCTAssertFalse(lines.isEmpty)
                    for line in lines {
                        let direction = SIMD2(Double(line.axis.z), Double(line.axis.w))
                        let edge = FocusLineGeometry.edge(center: center, direction: direction)
                        XCTAssertGreaterThan(Double(line.shape.y), edge)
                        XCTAssertLessThanOrEqual(line.shape.x, 241)
                        XCTAssertGreaterThanOrEqual(line.shape.x, 0)
                    }
                    if center.x == 960 {
                        let distances = lines.map { $0.shape.x }.sorted()
                        XCTAssertLessThan(distances[distances.count / 2], 80)
                    }
                }
            }
        }
        let canvas = try EffectTestCanvas()
        var clip = canvas.clip
        clip.effects = ImageEffects(sharpFocus: .init(thickness: 20, toneVariation: 0, seed: 42))
        for time in [0.0, 0.5] {
            try canvas.draw([(clip, 1)], time: time)
            let line = try XCTUnwrap(clip.effects?.sharpFocus?.lines(at: time).first)
            let point = SIMD2(line.axis.x, line.axis.y) + SIMD2(line.axis.z, line.axis.w) * 100
            XCTAssertGreaterThan(canvas.pixel(Int(point.x), Int(point.y))[0], 230)
            let edgeY = line.axis.y + (1919 - line.axis.x) * line.axis.w / line.axis.z
            XCTAssertGreaterThan(canvas.pixel(1919, Int(edgeY))[0], 230)
        }
    }

    func testVariationRevealsBackgroundWithoutDimmingColor() throws {
        let canvas = try EffectTestCanvas()
        var background = canvas.clip
        background.effects = ImageEffects(solidBackground: .init(color: .white))
        var clip = canvas.clip; clip.id = UUID()
        for color in [RGBColor.black, RGBColor(red: 1, green: 0, blue: 0)] {
            for opacity in [100.0, 50] {
                let effect = ImageEffects.SharpFocus(count: 8, thickness: 20, variation: 0,
                                                     toneVariation: 100, frequency: 0, color: color, seed: 42)
                clip.effects = ImageEffects(sharpFocus: effect)
                clip.fixedValues[.opacity] = opacity
                try canvas.draw([(background, 1), (clip, 2)])
                let line = try XCTUnwrap(effect.lines(at: 0).first)
                let alpha = Double(line.opacityScale.x) * opacity / 100
                let expected = 255 * (1.055 * pow(1 - alpha, 1 / 2.4) - 0.055)
                let pixel = canvas.pixel(1810, 540)
                XCTAssertEqual(Double(pixel[1]), expected, accuracy: 3)
                XCTAssertEqual(Double(pixel[2]), color.red == 1 ? 255 : expected, accuracy: 3)
                XCTAssertGreaterThan(pixel[1], 0, "線を通して背景が見える")
            }
        }
    }

    func testAutomationMusicAndPersistence() throws {
        var clip = VisualClip(assetID: nil, start: 0, end: 4, audioModulations: [:], effects: ImageEffects(sharpFocus: .init(seed: 42)))
        for parameter in ImageEffects.SharpFocus.parameters {
            let range = parameter.defaultRange
            _ = clip.setKey(parameter, at: 0, value: range.lowerBound)
            _ = clip.setKey(parameter, at: 2, value: range.upperBound)
            let value = try XCTUnwrap(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 1))))
            XCTAssertEqual(value, (range.lowerBound + range.upperBound) / 2, accuracy: 1e-6)
        }
        let before = clip.evaluatedEffects(at: 1.5)
        clip.trimStart(to: 1)
        let after = try XCTUnwrap(clip.evaluatedEffects(at: 1.5))
        for parameter in ImageEffects.SharpFocus.parameters {
            XCTAssertEqual(parameter.effect?.read(before!), parameter.effect?.read(after))
        }
        var track = VisualTrack(); track.layers[0].clips = [clip]
        try track.validate(duration: 4)
        let url = URL(fileURLWithPath: "/tmp/focus.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/song.wav"), visuals: track, settings: SceneSettings(), projectURL: url)
        let restored = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        try restored.validate()
        XCTAssertEqual(restored.visuals, track)
        var synced = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:], effects: ImageEffects(sharpFocus: .init(opacity: 0, seed: 42)))
        synced.audioModulations[.sharpOpacity] = AudioModulation(source: .beat, amount: 100)
        XCTAssertEqual(synced.evaluatedEffects(at: 0)?.sharpFocus?.opacity, 100)
        XCTAssertEqual(synced.evaluatedEffects(at: 0.3)?.sharpFocus?.opacity, 0)
        synced.audioModulations[.sharpCount] = AudioModulation(source: .beat, amount: 0.5)
        XCTAssertEqual(synced.evaluatedEffects(at: 0)?.sharpFocus?.count, 121)
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{\"nodes\":[],\"isBypassed\":false}".utf8)).sharpFocus)
    }
    func testRenderedInkMasksScaleAndOpacity() throws {
        let canvas = try EffectTestCanvas()
        let half = try EffectTestCanvas(scale: 0.5)
        var background = canvas.clip
        background.effects = ImageEffects(solidBackground: .init(color: .white))
        var clip = canvas.clip; clip.id = UUID()
        clip.effects = ImageEffects(sharpFocus: .init(variation: 0, toneVariation: 0, frequency: 0, color: .black, seed: 42))
        let line = try XCTUnwrap(clip.effects?.sharpFocus?.lines(at: 0).first)
        let sample = SIMD2(line.axis.x, line.axis.y) + SIMD2(line.axis.z, line.axis.w) * 850
        let x = Int(sample.x), y = Int(sample.y)
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertLessThan(canvas.pixel(x, y)[0], 20)
        XCTAssertEqual(canvas.pixel(960, 540), [255, 255, 255, 255])
        try canvas.save("/tmp/my-movie-sharp-preview.png")
        try half.draw([(background, 1), (clip, 2)])
        XCTAssertLessThan(half.pixel(x / 2, y / 2)[0], 30)
        clip.fixedValues[.opacity] = 0
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertEqual(canvas.pixel(x, y), [255, 255, 255, 255])
        clip.fixedValues[.opacity] = 50
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertEqual(Double(canvas.pixel(x, y)[0]), 188, accuracy: 3)
        clip.fixedValues[.opacity] = 100
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertEqual(canvas.pixel(x, y), [255, 255, 255, 255], "後段マスクは集中線３も切り抜く")
        var owner = canvas.clip; owner.id = UUID()
        owner.effects = ImageEffects(belowMask: .init(geometry: ShapeGeometry(width: 0)))
        try canvas.draw([(background, 1), (clip, 2), (owner, 3)])
        XCTAssertEqual(canvas.pixel(x, y), [255, 255, 255, 255])
        clip.effects?.mask = nil
        clip.effects?.sharpFocus?.color = .white
        background.effects?.solidBackground?.color = .black
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertGreaterThan(canvas.pixel(x, y)[0], 250)
        clip.effects?.sharpFocus?.count = 300
        clip.effects?.sharpFocus?.variation = 100
        var top = clip; top.id = UUID()
        var maxGPU = 0.0
        for i in 0..<9 {
            try canvas.draw([(background, 1), (clip, 2), (top, 3)], time: Double(i) / 8)
            maxGPU = max(maxGPU, canvas.lastGPUMS)
        }
        print("SHARP_RENDER gpu_max_ms=\(maxGPU)")
        clip.effects = ImageEffects(sharpFocus: .init(seed: 42))
        try canvas.draw([(background, 1), (clip, 2)])
        try canvas.save("/tmp/my-movie-sharp-default.png")
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
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "集中線３"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.sharpFocus)
        XCTAssertFalse(try XCTUnwrap(add.menu?.effectItem(titled: item.title + "（追加済み）")).isEnabled)
        let fields = all(editor).compactMap { $0 as? DragValueField }
        for parameter in ImageEffects.SharpFocus.parameters {
            let field = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let color = try XCTUnwrap(all(editor).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.sharpColor" })
        color.activate(true)
        NSColorPanel.shared.color = .red
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(clip.effects?.sharpFocus?.color, RGBColor(red: 1, green: 0, blue: 0))
        color.deactivate(); NSColorPanel.shared.orderOut(nil)
        let remove = try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.sharpFocus)
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
        let focus = ImageEffects.SharpFocus(thickness: 40, variation: 0, toneVariation: 0, frequency: 0, color: .white, seed: 42)
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(sharpFocus: focus))]
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
        // Flip Core Graphics so sample coordinates use the application's top-left origin.
        context.translateBy(x: 0, y: 1080); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(bytes[(540 * 1920 + 960) * 4], 80)
        XCTAssertGreaterThan(bytes[(540 * 1920 + 1810) * 4], 230)
    }

}
