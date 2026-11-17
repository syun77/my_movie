import AppKit
import AVFoundation
import XCTest
@testable import MVStudio

final class ZoomLoopTests: XCTestCase {
    private func sourceImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                                             space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<6 {
            for x in 0..<8 {
                context.setFillColor(CGColor(red: CGFloat(x + 1) / 8, green: CGFloat(y + 1) / 6, blue: CGFloat((x + y) % 3) / 2, alpha: 1))
                context.fill(CGRect(x: x * 24, y: y * 18, width: 24, height: 18))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func draw(_ clip: VisualClip, on canvas: EffectTestCanvas, source: CGImage, time: Double) throws {
        let commands = try canvas.renderer.encode(visuals: [VisualRenderLayer(clip: clip, image: source)], features: nil,
                                                  settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: time,
                                                  target: canvas.target, video: false)
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
    }

    func testPersistenceAutomationAndTrim() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(zoomLoop: .init()))
        for parameter in ImageEffects.ZoomLoop.parameters {
            let effect = try XCTUnwrap(parameter.effect)
            _ = clip.setKey(parameter, at: 1, value: effect.range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: effect.range.upperBound)
            XCTAssertTrue(clip.automationParameters.contains(parameter))
            XCTAssertEqual(effect.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), (effect.range.lowerBound + effect.range.upperBound) / 2)
        }
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.zoomLoop?.phaseOffset, 1)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        XCTAssertTrue(clip.effects?.isValid == true)
        clip.effects?.zoomLoop?.zoom = 0
        XCTAssertFalse(clip.effects?.isValid == true)
    }

    func testRenderingSeekOpacityAndTrim() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        let source = try sourceImage()
        var clip = canvas.clip
        clip.effects = ImageEffects(zoomLoop: .init())
        func pixels() -> [[UInt8]] {
            stride(from: 10, to: 270, by: 25).flatMap { y in
                stride(from: 10, to: 480, by: 25).map { canvas.pixel($0, y) }
            }
        }
        try draw(clip, on: canvas, source: source, time: 0.5)
        let first = pixels()
        XCTAssertTrue(first.contains { $0[0] > 30 })
        try canvas.save("/tmp/my-movie-zoom-loop-preview.png")
        try draw(clip, on: canvas, source: source, time: 1.5)
        XCTAssertNotEqual(first, pixels())
        try draw(clip, on: canvas, source: source, time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.trimStart(to: 0.25)
        try draw(clip, on: canvas, source: source, time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.effects?.zoomLoop?.opacity = 0
        try draw(clip, on: canvas, source: source, time: 0.5)
        let hidden = pixels()
        clip.effects = nil
        try draw(clip, on: canvas, source: source, time: 0.5)
        XCTAssertEqual(hidden, pixels())
    }
    func testSourceIdentityCenterMaskAndEmptyClip() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        let source = try sourceImage()
        var clip = canvas.clip
        func pixels() -> [[UInt8]] { stride(from: 10, to: 270, by: 20).flatMap { y in
            stride(from: 10, to: 480, by: 20).map { canvas.pixel($0, y) }
        } }
        try draw(clip, on: canvas, source: source, time: 0)
        let original = pixels()
        clip.effects = ImageEffects(zoomLoop: .init())
        try draw(clip, on: canvas, source: source, time: 0)
        XCTAssertEqual(original, pixels(), "周期の始点では素材の色と向きを維持")
        try draw(clip, on: canvas, source: source, time: 0.7)
        let animated = pixels()
        XCTAssertNotEqual(original, animated)
        clip.effects?.zoomLoop?.centerX = 300
        try draw(clip, on: canvas, source: source, time: 0.7)
        XCTAssertNotEqual(animated, pixels())
        clip.effects?.zoomLoop?.isEnabled = false
        try draw(clip, on: canvas, source: source, time: 0.7)
        XCTAssertEqual(original, pixels())
        clip.effects?.zoomLoop?.isEnabled = true
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try draw(clip, on: canvas, source: source, time: 0.7)
        let masked = pixels()
        clip.effects = nil
        try canvas.draw([(clip, 1)], time: 0.7)
        let empty = pixels()
        XCTAssertEqual(masked, empty)
        clip.effects = ImageEffects(zoomLoop: .init())
        try canvas.draw([(clip, 1)], time: 0.7)
        XCTAssertEqual(empty, pixels(), "空素材から人物や背景を生成しない")
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
        let imageURL = directory.appendingPathComponent("pattern.png")
        let bitmap = NSBitmapImageRep(cgImage: try sourceImage())
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        let project = ProjectStorage.projectURL(for: audio)
        let imageAsset = VisualAsset(reference: AssetReference(url: imageURL, projectURL: project))
        track.assets.append(imageAsset)
        let focus = ImageEffects.ZoomLoop()
        track.layers[0].clips = [VisualClip(assetID: imageAsset.id, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(zoomLoop: focus))]
        let output = directory.appendingPathComponent("zoom-loop.mp4")
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
        let colored = (0..<(1920 * 1080)).filter { bytes[$0 * 4] > 120 && bytes[$0 * 4 + 1] > 80 && bytes[$0 * 4 + 2] > 60 }
        XCTAssertGreaterThan(colored.count, 1000, "素材画像がMP4にも描画される")
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
        let item = try XCTUnwrap(add.menu?.item(withTitle: "拡大ループ"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.zoomLoop)
        XCTAssertFalse(item.isEnabled)
        for parameter in ImageEffects.ZoomLoop.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, try XCTUnwrap(parameter.effect).initial)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.zoomLoop?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.zoomLoop)
    }

}
