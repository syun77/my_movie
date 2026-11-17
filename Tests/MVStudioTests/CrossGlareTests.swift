import AppKit
import XCTest
import Metal
import AVFoundation
@testable import MVStudio

final class CrossGlareTests: XCTestCase {
    func testPersistenceAutomationAndValidation() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(crossGlare: .init()))
        for parameter in ImageEffects.CrossGlare.parameters {
            let range = try XCTUnwrap(parameter.effect?.range)
            _ = clip.setKey(parameter, at: 1, value: range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: range.upperBound)
            XCTAssertEqual(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), (range.lowerBound + range.upperBound) / 2)
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.effects?.crossGlare?.length = .nan
        XCTAssertFalse(clip.effects?.isValid == true)
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{}".utf8)).crossGlare)
    }

    func testRenderingAndCacheInvalidation() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(shape: .init(), crossGlare: .init(threshold: 30, intensity: 200, length: 160, width: 4, angle: 0))
        clip.effects?.shape?.color = .init(red: 1, green: 1, blue: 1)
        clip.effects?.shape?.geometry.width = 40
        clip.effects?.shape?.geometry.height = 40
        try canvas.draw([(clip, 0)])
        let lit = canvas.pixel(255, 135)
        XCTAssertGreaterThan(lit[0], 30)
        try canvas.save("/tmp/my-movie-cross-preview.png")
        clip.effects?.crossGlare?.angle = 45
        try canvas.draw([(clip, 0)])
        XCTAssertLessThan(canvas.pixel(255, 135)[0], lit[0])
        for disabled in [ImageEffects.CrossGlare(isEnabled: false), .init(threshold: 100), .init(intensity: 0), .init(length: 0)] {
            clip.effects?.crossGlare = disabled
            try canvas.draw([(clip, 0)])
            XCTAssertLessThan(canvas.pixel(255, 135)[0], 25)
        }
        clip.effects?.shape = nil
        clip.effects?.crossGlare = .init()
        try canvas.draw([(clip, 0)])
        XCTAssertLessThan(canvas.pixel(240, 135)[0], 25)
    }

    func testOpacityMaskLoopAndSeek() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(shape: .init(), crossGlare: .init(threshold: 0, intensity: 200, angle: 0), zoomLoop: .init())
        clip.effects?.shape?.color = .init(red: 1, green: 0, blue: 0)
        clip.effects?.shape?.geometry.width = 80
        clip.effects?.shape?.geometry.height = 80
        func pixels() -> [[UInt8]] {
            stride(from: 90, to: 180, by: 5).flatMap { y in stride(from: 190, to: 290, by: 5).map { canvas.pixel($0, y) } }
        }
        try canvas.draw([(clip, 0)], time: 0.5)
        let first = pixels()
        try canvas.draw([(clip, 0)], time: 0.8)
        XCTAssertNotEqual(first, pixels())
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(clip, 0)])
        let masked = pixels()
        clip.effects?.mask = nil
        clip.fixedValues[.opacity] = 0
        try canvas.draw([(clip, 0)])
        XCTAssertEqual(masked, pixels())
        clip.effects = nil
        try canvas.draw([(clip, 0)])
        XCTAssertEqual(masked, pixels())
    }

    func testFiniteSupportPlan() {
        for radius in [0.0, 0.25, 1, 2, 3, 159.99, 160, 600] {
            let steps = CrossGlareRenderer.steps(radius: radius)
            XCTAssertEqual(steps.reduce(0, +), radius, accuracy: 0.000001)
            XCTAssertLessThanOrEqual(steps.count, 10)
        }
    }
    func testGPUAgainstReferenceAndTransparentRGB() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try CrossGlareRenderer(device: device, library: SceneShaders.library(device: device))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 33, height: 33, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [SIMD4<Float>](repeating: .zero, count: 33 * 33)
        pixels[16 * 33 + 16] = SIMD4(1, 0, 0, 1)
        // Hidden RGB in transparent pixels must not contribute light.
        pixels[3 * 33 + 3] = SIMD4(100, 100, 100, 0)
        pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 33, 33), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 33 * 16) }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try renderer.render(input, effect: .init(threshold: 0, length: 7, width: 2, angle: 0), scale: 1, reusing: nil, commands: commands)
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
        var result = [UInt16](repeating: 0, count: 33 * 33 * 4)
        output.getBytes(&result, bytesPerRow: 33 * 8, from: MTLRegionMake2D(0, 0, 33, 33), mipmapLevel: 0)
        func convolve(_ source: [Float], dx: Int, dy: Int) -> [Float] {
            var target = source
            for y in 0..<33 { for x in 0..<33 {
                func sample(_ x: Int, _ y: Int) -> Float { (0..<33).contains(x) && (0..<33).contains(y) ? source[y * 33 + x] : 0 }
                target[y * 33 + x] = sample(x, y) * 0.5 + (sample(x - dx, y - dy) + sample(x + dx, y + dy)) * 0.25
            } }
            return target
        }
        var emission = [Float](repeating: 0, count: 33 * 33)
        emission[16 * 33 + 16] = 0.2126
        var horizontal = emission, vertical = emission
        for step in [1, 2, 4] {
            horizontal = convolve(horizontal, dx: step, dy: 0)
            vertical = convolve(vertical, dx: 0, dy: step)
        }
        horizontal = convolve(horizontal, dx: 0, dy: 1)
        vertical = convolve(vertical, dx: 1, dy: 0)
        for index in emission.indices {
            let expected = (horizontal[index] + vertical[index]) * 0.5
            XCTAssertEqual(Float(Float16(bitPattern: result[index * 4])), expected, accuracy: 0.0001)
            XCTAssertEqual(Float(Float16(bitPattern: result[index * 4 + 1])), 0)
        }
    }

    func testMaximumThreeLayerPerformance() throws {
        let canvas = try EffectTestCanvas()
        var clips: [(VisualClip, Int)] = []
        for slot in 0..<3 {
            var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
            clip.effects = ImageEffects(shape: .init(), crossGlare: .init(length: 600, width: 20))
            clips.append((clip, slot))
        }
        try canvas.draw(clips)
        print("CrossGlare maximum three layers: encode=\(canvas.lastEncodeMS)ms GPU=\(canvas.lastGPUMS)ms")
        try canvas.draw(clips)
        print("CrossGlare repeated three layers: encode=\(canvas.lastEncodeMS)ms GPU=\(canvas.lastGPUMS)ms")
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
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(shape: .init(geometry: ShapeGeometry(width: 40, height: 40), color: .init(red: 1, green: 1, blue: 1)), crossGlare: .init(threshold: 30, intensity: 200, length: 160, angle: 0))) ]
        let output = directory.appendingPathComponent("cross-glare.mp4")
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
        let ray = (540 * 1920 + 1020) * 4
        XCTAssertGreaterThan(bytes[ray], 30, "クロスグレアの光条がMP4に残る")
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
        let item = try XCTUnwrap(add.menu?.item(withTitle: "クロスグレア"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.crossGlare)
        XCTAssertFalse(item.isEnabled)
        for parameter in ImageEffects.CrossGlare.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.effect?.initial)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.crossGlare?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.crossGlare)
    }

}
