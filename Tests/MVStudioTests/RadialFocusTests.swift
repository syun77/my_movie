import AppKit
import AVFoundation
import XCTest
@testable import MVStudio

final class RadialFocusTests: XCTestCase {
    func testPersistenceAutomationAndTrim() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(radialFocus: .init()))
        for parameter in ImageEffects.RadialFocus.parameters {
            let effect = try XCTUnwrap(parameter.effect)
            _ = clip.setKey(parameter, at: 1, value: effect.range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: effect.range.upperBound)
            XCTAssertTrue(clip.automationParameters.contains(parameter))
            XCTAssertEqual(effect.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), (effect.range.lowerBound + effect.range.upperBound) / 2)
        }
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.radialFocus?.phaseOffset, 1)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        XCTAssertTrue(clip.effects?.isValid == true)
        clip.effects?.radialFocus?.zoom = 0
        XCTAssertFalse(clip.effects?.isValid == true)
    }

    func testRenderingSeekOpacityAndTrim() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(radialFocus: .init())
        func pixels() -> [[UInt8]] {
            stride(from: 10, to: 270, by: 25).flatMap { y in
                stride(from: 10, to: 480, by: 25).map { canvas.pixel($0, y) }
            }
        }
        try canvas.draw([(clip, 1)], time: 0.5)
        let first = pixels()
        try canvas.draw([(clip, 1)], time: 0.59)
        XCTAssertEqual(first, pixels(), "10Hzの同じコマ内は変わらない")
        XCTAssertTrue(first.contains { $0[0] > 30 })
        try canvas.save("/tmp/my-movie-radial-focus-preview.png")
        try canvas.draw([(clip, 1)], time: 1.5)
        XCTAssertNotEqual(first, pixels())
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.trimStart(to: 0.25)
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.effects?.radialFocus?.opacity = 0
        try canvas.draw([(clip, 1)], time: 0.5)
        let hidden = pixels()
        clip.effects = nil
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(hidden, pixels())
        clip.effects = ImageEffects(radialFocus: .init(speed: 0))
        try canvas.draw([(clip, 1)], time: 0.5)
        let still = pixels()
        try canvas.draw([(clip, 1)], time: 1.5)
        XCTAssertEqual(still, pixels())
        clip.effects?.radialFocus?.brightness = 0
        try canvas.draw([(clip, 1)], time: 1.5)
        XCTAssertEqual(hidden, pixels())
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
        let focus = ImageEffects.RadialFocus()
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(radialFocus: focus))]
        let output = directory.appendingPathComponent("radial-focus.mp4")
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
        let colored = (0..<(1920 * 1080)).filter { bytes[$0 * 4 + 2] > 80 && Int(bytes[$0 * 4 + 2]) > Int(bytes[$0 * 4]) + 20 }
        XCTAssertGreaterThan(colored.count, 1000, "青い放射状ノイズがMP4にも描画される")
    }

    @MainActor func testEditorAddToggleDeleteAndAutomation() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
        func load() { editor.load(clip, editable: true) }
        load()
        editor.onCommit = { clip.effects = $0; load() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.item(withTitle: "集中線２"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.radialFocus)
        XCTAssertFalse(item.isEnabled)
        for parameter in ImageEffects.RadialFocus.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, 100)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.radialFocus?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.radialFocus)
    }

    func testAdditiveCompositionAndBelowMask() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var background = canvas.clip
        background.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 0.3, green: 0.2, blue: 0)))
        var clip = canvas.clip; clip.id = UUID()
        clip.effects = ImageEffects(radialFocus: .init())
        let points = stride(from: 20, to: 460, by: 30).map { ($0, 40) }
        func pixels() -> [[UInt8]] { points.map { canvas.pixel($0.0, $0.1) } }
        try canvas.draw([(background, 1)])
        let base = pixels()
        try canvas.draw([(background, 1), (clip, 2)])
        let lit = pixels()
        XCTAssertTrue(zip(base, lit).allSatisfy { $1[2] >= $0[2] && $1[1] >= $0[1] }, "加算光は背景を暗くしない")
        XCTAssertTrue(zip(base, lit).contains { $1[0] > $0[0] + 10 })
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertEqual(lit, pixels(), "自画像マスク対象外")
        var owner = canvas.clip; owner.id = UUID()
        owner.effects = ImageEffects(mask: .init(geometry: ShapeGeometry(width: 0), target: .below))
        try canvas.draw([(background, 1), (clip, 2), (owner, 3)])
        XCTAssertEqual(base, pixels(), "下段マスクは集中線２も切り抜く")
        clip.fixedValues[.opacity] = 0
        try canvas.draw([(background, 1), (clip, 2)])
        XCTAssertEqual(base, pixels())
    }

}
