import AppKit
import XCTest
import CoreImage
import AVFoundation
@testable import MVStudio

final class VignetteTests: XCTestCase {
    func testPersistenceAutomationAndValidation() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(vignette: .init()))
        for parameter in [ImageParameter.vignetteStrength, .vignetteSize, .vignetteSoftness] {
            _ = clip.setKey(parameter, at: 1, value: 0)
            _ = clip.setKey(parameter, at: 3, value: 100)
            XCTAssertEqual(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), 50)
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.effects?.vignette?.strength = .nan
        XCTAssertFalse(clip.effects?.isValid == true)
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{\"nodes\":[],\"isBypassed\":false}".utf8)).vignette)
    }

    func testRenderingAndCacheInvalidation() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(solidBackground: .init(color: .init(red: 1, green: 1, blue: 1)), vignette: .init())
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(240, 135)[0], 245)
        let corner = canvas.pixel(5, 5)[0]
        XCTAssertLessThan(corner, 200)
        try canvas.save("/tmp/my-movie-vignette-preview.png")
        clip.effects?.vignette?.strength = 100
        try canvas.draw([(clip, 0)])
        XCTAssertLessThan(canvas.pixel(5, 5)[0], corner)
        XCTAssertGreaterThan(canvas.pixel(5, 5)[0], 3, "光学風の裾は黒へ急に切り落とさない")
        clip.effects?.vignette?.strength = 0
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(5, 5)[0], 250)
        clip.effects?.vignette = .init(isEnabled: false)
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(5, 5)[0], 250)
        clip.effects?.solidBackground = nil
        clip.effects?.vignette = .init()
        var underlying = canvas.clip
        underlying.id = UUID()
        underlying.effects = ImageEffects(solidBackground: .init(color: .init(red: 1, green: 1, blue: 1)))
        try canvas.draw([(underlying, 0), (clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(5, 5)[0], 250, "透明部分を黒く塗りつぶさない")
    }
    func testOpticalCurveAgainstLinearReferenceAlphaScaleAndPadding() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        for dimensions in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080)] {
            for scale in [0.1, 0.25] {
                let canvas = CGRect(x: 0, y: 0, width: dimensions.width * scale, height: dimensions.height * scale)
                for padding in [0.0, 17 * scale] {
                    let bounds = CGRect(x: 0, y: 0, width: canvas.width + 2 * padding, height: canvas.height + 2 * padding).integral
                    let color = try XCTUnwrap(CIColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.5, colorSpace: space))
                    let input = CIImage(color: color).cropped(to: bounds)
                    for effect in [ImageEffects.Vignette(), .init(strength: 100, size: 0, softness: 0), .init(strength: 100, size: 100, softness: 100), .init(strength: 0), .init(isEnabled: false)] {
                        let output = try VignetteRenderer.apply(effect, to: input, canvas: canvas, padding: padding, scale: scale)
                        let width = Int(bounds.width), height = Int(bounds.height)
                        var result = [Float](repeating: 0, count: width * height * 4)
                        result.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: space) }
                        let radius = sqrt(2.0) * effect.size / 100
                        let transition = max(scale / min(canvas.width, canvas.height), radius * effect.softness / 100)
                        let inner = max(0, radius - transition)
                        for y in stride(from: 0, to: height, by: 7) {
                            for x in stride(from: 0, to: width, by: 7) {
                                let distance = hypot((Double(x) + 0.5 - canvas.midX - padding) / (canvas.width / 2),
                                                     (bounds.maxY - Double(y) - 0.5 - canvas.midY - padding) / (canvas.height / 2))
                                let t = max(0, distance - inner) / transition
                                let optical = 1 / pow(1 + t * t, 2)
                                let attenuation = effect.isEnabled ? 1 - effect.strength / 100 * (1 - optical) : 1
                                let index = (y * width + x) * 4
                                for (channel, value) in [0.4, 0.2, 0.1].enumerated() {
                                    XCTAssertEqual(Double(result[index + channel]), value * attenuation, accuracy: 0.0003)
                                }
                                XCTAssertEqual(result[index + 3], 0.5, accuracy: 0.0001)
                            }
                        }
                    }
                }
            }
        }
    }

    func testEqualAttenuationAtMatchingHorizontalAndVerticalFractions() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(solidBackground: .init(color: .init(red: 1, green: 1, blue: 1)), vignette: .init())
        try canvas.draw([(clip, 0)])
        for fraction in [0.5, 0.7, 0.9] {
            let horizontal = canvas.pixel(Int(240 + 240 * fraction), 135)[0]
            let vertical = canvas.pixel(240, Int(135 + 135 * fraction))[0]
            XCTAssertEqual(Double(horizontal), Double(vertical), accuracy: 2,
                           "画面幅/高さに対する同じ割合の位置は同じ減光になる")
        }
    }

    func testRadialMonotonicityAndStableSeek() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(solidBackground: .init(color: .init(red: 0.2, green: 0.2, blue: 0.2)), vignette: .init())
        try canvas.draw([(clip, 0)], time: 0.2)
        let first = (0..<480).map { canvas.pixel($0, 135)[0] }
        for x in 240..<479 { XCTAssertGreaterThanOrEqual(Int(first[x]) + 1, Int(first[x + 1])) }
        for x in 1..<240 { XCTAssertEqual(Double(first[x]), Double(first[479 - x]), accuracy: 1) }
        for fraction in [0.65, 0.8, 0.98] {
            let horizontal = canvas.pixel(Int(240 * (1 + fraction) - 0.5), 135)[0]
            let vertical = canvas.pixel(240, Int(135 * (1 + fraction) - 0.5))[0]
            XCTAssertEqual(Double(horizontal), Double(vertical), accuracy: 1, "画面の幅/高さに対する同じ割合では減光も等しい")
        }
        try canvas.draw([(clip, 0)], time: 1.5)
        XCTAssertEqual(first, (0..<480).map { canvas.pixel($0, 135)[0] })
        try canvas.save("/tmp/my-movie-vignette-quality-dark.png")
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
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects:
            ImageEffects(solidBackground: .init(color: .init(red: 0.2, green: 0.2, blue: 0.2)), vignette: .init()))]
        let output = directory.appendingPathComponent("vignette.mp4")
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
        func average(_ x: Int, _ y: Int) -> Double {
            var total = 0.0
            for dy in -2...2 { for dx in -2...2 { total += Double(bytes[((y + dy) * 1920 + x + dx) * 4]) } }
            return total / 25
        }
        let center = average(960, 540)
        let corner = average(20, 20)
        XCTAssertGreaterThan(center, corner + 12)
        XCTAssertGreaterThan(corner, 5, "暗部の階調を維持する")
        var previous = center
        for x in stride(from: 1000, through: 1900, by: 50) {
            let value = average(x, 540)
            XCTAssertLessThanOrEqual(value, previous + 2)
            previous = value
        }
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
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "Vignette（周辺減光）"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.vignette)
        XCTAssertFalse(try XCTUnwrap(add.menu?.effectItem(titled: item.title + "（追加済み）")).isEnabled)
        for parameter in [ImageParameter.vignetteStrength, .vignetteSize, .vignetteSoftness] {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.effect?.initial)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.vignette?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.vignette)
    }

}
