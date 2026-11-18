import AppKit
import XCTest
import Metal
import AVFoundation
@testable import MVStudio

final class RadialBlurTests: XCTestCase {
    func testPersistenceAutomationAndValidation() throws {
        var clip = VisualClip(assetID: nil, start: 0, end: 4, audioModulations: [:], effects: ImageEffects(radialBlur: .init()))
        for parameter in ImageEffects.RadialBlur.parameters {
            let range = try XCTUnwrap(parameter.effect?.range)
            _ = clip.setKey(parameter, at: 0, value: range.lowerBound)
            _ = clip.setKey(parameter, at: 4, value: range.upperBound)
            XCTAssertEqual(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), (range.lowerBound + range.upperBound) / 2)
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.effects?.radialBlur?.strength = .nan
        XCTAssertFalse(clip.effects?.isValid == true)
    }

    func testCompositionCacheAndTransparentEdges() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(shape: .init(geometry: ShapeGeometry(kind: .rectangle, width: 300, height: 300, x: 1400, y: 540)), radialBlur: .init(strength: 100))
        try canvas.draw([(clip, 0)])
        let background = canvas.pixel(10, 10)[0]
        let blurred = canvas.pixel(315, 135)[0]
        clip.effects?.radialBlur?.strength = 0
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(315, 135)[0], blurred)
        XCTAssertEqual(canvas.pixel(10, 10)[0], background)
        clip.effects?.radialBlur?.strength = 100
        try canvas.draw([(clip, 0)])
        XCTAssertEqual(canvas.pixel(315, 135)[0], blurred)
    }

    func testCombinedFiltersThreeLayersAndAnimatedSeek() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clips: [(VisualClip, Int)] = []
        for slot in 0..<3 {
            var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
            clip.effects = ImageEffects(shape: .init(geometry: ShapeGeometry(width: 300, height: 300, x: 1400, y: 400 + Double(slot) * 150)),
                mask: .init(geometry: ShapeGeometry(kind: .ellipse, width: 1600, height: 1000)),
                blur: .init(radius: 2), radialBlur: .init(strength: 100), bloom: .init(threshold: 20), colorCorrection: .init(hue: 20))
            clip.fixedValues[.opacity] = 70
            _ = clip.setKey(.radialBlurStrength, at: 0, value: 0)
            _ = clip.setKey(.radialBlurStrength, at: 1, value: 100)
            clips.append((clip, slot))
        }
        func pixels() -> [[UInt8]] { stride(from: 50, to: 240, by: 10).flatMap { y in stride(from: 250, to: 470, by: 5).map { canvas.pixel($0, y) } } }
        try canvas.draw(clips, time: 0.5)
        let first = pixels()
        print("RADIAL threeLayers preview GPU=\(canvas.lastGPUMS)ms")
        try canvas.save("/tmp/my-movie-radial-quality-preview.png")
        try canvas.draw(clips, time: 0.8)
        XCTAssertNotEqual(first, pixels())
        try canvas.draw(clips, time: 0.5)
        XCTAssertEqual(first, pixels())
        canvas.renderer.discardCache()
        try canvas.draw(clips, time: 0.5)
        XCTAssertEqual(first, pixels())
    }

    func testFixedIntervalAndCenterClampAgainstReference() throws {
        let gpu = try RadialBlurTestRenderer(width: 192, height: 108, padding: 2) { x, y in
            SIMD4(Float(x) / 191, Float(y) / 107, 0.125, 0.5)
        }
        for center in [(480.0, 270.0), (0, 0), (1920, 1080)] {
            for count in [2.0, 64, 128, 256] {
                let effect = ImageEffects.RadialBlur(strength: 100, sampleCount: count, centerX: center.0, centerY: center.1)
                let result = try gpu.draw(effect)
                for (x, y) in [(140, 70), (1, 1), (190, 106), (80, 45)] {
                    let reference = gpu.reference(effect, x: x, y: y)
                    for channel in 0..<4 { XCTAssertEqual(result[y * 192 + x][channel], reference[channel], accuracy: 0.001) }
                }
            }
        }
    }

    func testThinLinesAgainstConvergedReferenceAndQualityBudget() throws {
        let gpu = try RadialBlurTestRenderer(width: 1920, height: 1080) { x, y in
            let value: Float = x % 13 == 0 || y % 17 == 0 ? 1 : 0
            return SIMD4(value * 0.5, value * 0.25, value * 0.125, value * 0.5)
        }
        let points = stride(from: 50, to: 1050, by: 111).flatMap { y in stride(from: 30, to: 1900, by: 123).map { ($0, y) } }
        var errors: [Float] = []
        for count in [64.0, 128, 256] {
            let effect = ImageEffects.RadialBlur(strength: 100, sampleCount: count)
            let result = try gpu.draw(effect)
            var squared: Float = 0
            for (x, y) in points {
                let reference = gpu.reference(effect, x: x, y: y, count: 4096)
                let converged = gpu.reference(effect, x: x, y: y, count: 8192)
                XCTAssertEqual(reference.x, converged.x, accuracy: 0.001)
                let pixel = result[y * 1920 + x]
                squared += pow(pixel.x - reference.x, 2)
                XCTAssertEqual(pixel.x, pixel.w, accuracy: 0.001)
                XCTAssertEqual(pixel.y * 2, pixel.x, accuracy: 0.001)
            }
            errors.append(sqrt(squared / Float(points.count)))
            print("RADIAL quality=\(count) rms=\(errors.last!) gpuMS=\(gpu.lastGPUMS)")
        }
        XCTAssertLessThan(errors[2], errors[0] * 0.5)
        let effect = ImageEffects.RadialBlur(strength: 100)
        let first = try gpu.draw(effect)
        let unjittered = try gpu.draw(effect, jitter: 0)
        var squared: Float = 0
        for (x, y) in points {
            let reference = gpu.reference(effect, x: x, y: y)
            squared += pow(unjittered[y * 1920 + x].x - reference.x, 2)
        }
        print("RADIAL jitterOffRMS=\(sqrt(squared / Float(points.count)))")
        XCTAssertEqual(first, try gpu.draw(effect), "描画履歴や時刻に依存せず再現する")
        let bypass = try gpu.draw(.init(strength: 0))
        XCTAssertEqual(bypass[13], gpu.pixels[13])
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
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(shape: .init(geometry: ShapeGeometry(width: 300, height: 300, x: 1400, y: 540), color: .init(red: 1, green: 1, blue: 1)), radialBlur: .init(strength: 100))) ]
        let output = directory.appendingPathComponent("radial-blur.mp4")
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
        let ray = (540 * 1920 + 1600) * 4
        XCTAssertGreaterThan(bytes[ray], 30, "放射方向の流れがMP4に残る")
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
        let item = try XCTUnwrap(add.menu?.item(withTitle: "放射ブラー"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.radialBlur)
        XCTAssertFalse(item.isEnabled)
        for parameter in ImageEffects.RadialBlur.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.effect?.initial)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.radialBlur?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.radialBlur)
    }

}


private final class RadialBlurTestRenderer {
    let width: Int
    let height: Int
    let pixels: [SIMD4<Float>]
    let padding: Double
    let device: MTLDevice
    let queue: MTLCommandQueue
    let renderer: RadialBlurRenderer
    let source: MTLTexture
    private(set) var lastGPUMS = 0.0

    init(width: Int, height: Int, padding: Double = 0, pixel: (Int, Int) -> SIMD4<Float>) throws {
        self.width = width; self.height = height; self.padding = padding
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        renderer = try RadialBlurRenderer(device: device, library: SceneShaders.library(device: device))
        pixels = (0..<height).flatMap { y in (0..<width).map { pixel($0, y) } }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
    }

    func draw(_ effect: ImageEffects.RadialBlur, jitter: Float = 0.35) throws -> [SIMD4<Float>] {
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try renderer.render(source, effect: effect, canvas: CGSize(width: Double(width) - 2 * padding, height: Double(height) - 2 * padding), padding: padding,
                                         reusing: nil, commands: commands, jitter: jitter)
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
        lastGPUMS = (commands.gpuEndTime - commands.gpuStartTime) * 1000
        if output === source { return pixels }
        var values = [UInt16](repeating: 0, count: width * height * 4)
        output.getBytes(&values, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return stride(from: 0, to: values.count, by: 4).map { i in SIMD4(Float(Float16(bitPattern: values[i])), Float(Float16(bitPattern: values[i+1])), Float(Float16(bitPattern: values[i+2])), Float(Float16(bitPattern: values[i+3]))) }
    }

    func reference(_ effect: ImageEffects.RadialBlur, x: Int, y: Int, count: Int = 4096) -> SIMD4<Float> {
        let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
        let canvas = SIMD2(Double(width) - 2 * padding, Double(height) - 2 * padding)
        let delta = (point - SIMD2(repeating: padding)) / canvas - SIMD2(effect.centerX / 1920, 1 - effect.centerY / 1080)
        let amount = min(1, effect.strength / 100 * hypot(delta.x, delta.y))
        let travel = delta * canvas * amount
        var total = SIMD4<Double>.zero
        for i in 0..<count {
            let q = point - travel * ((Double(i) + 0.5) / Double(count)) - SIMD2(repeating: 0.5)
            let ix = Int(floor(q.x)), iy = Int(floor(q.y))
            let fx = q.x - Double(ix), fy = q.y - Double(iy)
            for dy in 0...1 { for dx in 0...1 {
                let sx = ix + dx, sy = iy + dy
                if sx >= 0 && sx < width && sy >= 0 && sy < height {
                    let weight = (dx == 0 ? 1 - fx : fx) * (dy == 0 ? 1 - fy : fy)
                    total += SIMD4<Double>(pixels[sy * width + sx]) * weight
                }
            } }
        }
        return SIMD4<Float>(total / Double(count))
    }
}
