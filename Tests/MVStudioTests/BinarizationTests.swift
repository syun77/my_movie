import AppKit
import CoreImage
import AVFoundation
import XCTest
@testable import MVStudio

final class BinarizationTests: XCTestCase {
    func testPersistenceValidationAndAutomation() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:],
                              effects: ImageEffects(binarization: .init()))
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{\"nodes\":[],\"isBypassed\":false}".utf8)).binarization)
        for parameter in [ImageParameter.binarizationThreshold, .binarizationAmount] {
            _ = clip.setKey(parameter, at: 1, value: 20)
            _ = clip.setKey(parameter, at: 3, value: 80)
            XCTAssertEqual(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), 50)
            clip.audioModulations[parameter] = AudioModulation(source: .beat, amount: 80)
            let settings = SceneSettings(bpm: 120, beatOffset: 0)
            XCTAssertEqual(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 2, settings: settings))), 100)
            let first = clip.evaluatedEffects(at: 2.1, settings: settings)
            _ = clip.evaluatedEffects(at: 3.2, settings: settings)
            XCTAssertEqual(first, clip.evaluatedEffects(at: 2.1, settings: settings))
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.effects?.binarization?.threshold = .nan
        XCTAssertFalse(try XCTUnwrap(clip.effects).isValid)
        clip.effects?.binarization = .init(amount: 101)
        XCTAssertFalse(try XCTUnwrap(clip.effects).isValid)
        clip.effects?.binarization = .init(darkColor: RGBColor(red: -1, green: 0, blue: 0))
        XCTAssertFalse(try XCTUnwrap(clip.effects).isValid)
    }

    func testThresholdEndpointsColorsMixAndAlpha() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        func sample(_ rgb: [Double], alpha: Double, effect: ImageEffects.Binarization) throws -> [Float] {
            let input = CIImage(color: try XCTUnwrap(CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha, colorSpace: space)))
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            let output = try BinarizationRenderer.apply(effect, to: input)
            var values = [Float](repeating: -1, count: 4)
            values.withUnsafeMutableBytes {
                context.render(output, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: input.extent, format: .RGBAf, colorSpace: space)
            }
            return values
        }
        for (rgb, high) in [([0.0, 0, 0], false), ([1.0, 1, 1], true),
                            ([linear(0.49), linear(0.49), linear(0.49)], false),
                            ([linear(0.51), linear(0.51), linear(0.51)], true),
                            ([1.0, 0, 0], false), ([0.0, 1, 0], true), ([0.0, 0, 1], false)] {
            for alpha in [0.0, 0.5, 1] {
                let pixel = try sample(rgb, alpha: alpha, effect: .init())
                for channel in 0..<3 { XCTAssertEqual(pixel[channel], Float(high ? alpha : 0), accuracy: 0.0003) }
                XCTAssertEqual(pixel[3], Float(alpha), accuracy: 0.0001)
            }
        }
        for threshold in [0.0, 100] {
            for rgb in [[0.0, 0, 0], [1.0, 1, 1]] {
                let pixel = try sample(rgb, alpha: 0.5, effect: .init(threshold: threshold))
                XCTAssertEqual(pixel[0], threshold == 0 ? 0.5 : 0, accuracy: 0.0001)
            }
        }
        // Red's encoded brightness equals 21.26%, including the threshold itself.
        XCTAssertEqual(try sample([1, 0, 0], alpha: 1, effect: .init(threshold: 21.26))[0], 1, accuracy: 0.0001)
        var effect = ImageEffects.Binarization(darkColor: .init(red: 0.25, green: 0.5, blue: 0.75),
                                                lightColor: .init(red: 1, green: 0, blue: 0))
        let original = effect
        effect.swapColors()
        XCTAssertEqual(effect.darkColor, original.lightColor)
        XCTAssertEqual(effect.lightColor, original.darkColor)
        for amount in [0.0, 50, 100] {
            effect.amount = amount
            let pixel = try sample([0.2, 0.2, 0.2], alpha: 0.5, effect: effect)
            for (channel, target) in [1.0, 0, 0].enumerated() {
                XCTAssertEqual(Double(pixel[channel]), (0.2 * (1 - amount / 100) + target * amount / 100) * 0.5, accuracy: 0.0003)
            }
        }
        let colored = try sample([0, 0, 0], alpha: 0.5, effect: original)
        for (channel, target) in [0.25, 0.5, 0.75].enumerated() {
            XCTAssertEqual(Double(colored[channel]), linear(target) * 0.5, accuracy: 0.0003)
        }
        let bypass = try sample([0.2, 0.4, 0.6], alpha: 0.5, effect: .init(isEnabled: false))
        XCTAssertEqual(bypass[0], 0.1, accuracy: 0.0001)
    }

    func testSharedRendererOrderCacheAndRadialBlur() throws {
        let canvas = try EffectTestCanvas(scale: 0.1)
        var clip = canvas.clip
        clip.effects = ImageEffects(solidBackground: .init(color: .init(red: 0.6, green: 0.6, blue: 0.6)),
                                   binarization: .init())
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(96, 54)[0], 250)
        clip.effects?.binarization?.threshold = 70
        try canvas.draw([(clip, 0)])
        XCTAssertLessThan(canvas.pixel(96, 54)[0], 3)
        clip.effects?.binarization?.amount = 0
        try canvas.draw([(clip, 0)])
        XCTAssertEqual(Double(canvas.pixel(96, 54)[0]), 153, accuracy: 2)
        clip.effects?.binarization = .init()
        clip.effects?.colorCorrection = .init(brightness: -100)
        try canvas.draw([(clip, 0)])
        XCTAssertLessThan(canvas.pixel(96, 54)[0], 3)
        clip.effects?.colorCorrection = nil
        clip.effects?.radialBlur = .init(strength: 20)
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(96, 54)[0], 250)
        clip.effects?.binarization?.lightColor = .init(red: 1, green: 0, blue: 0)
        try canvas.draw([(clip, 0)])
        XCTAssertGreaterThan(canvas.pixel(96, 54)[2], 250)
        XCTAssertLessThan(canvas.pixel(96, 54)[0], 3)
        try canvas.save("/tmp/my-movie-binarization-preview.png")
        clip.effects?.solidBackground = nil
        clip.effects?.radialBlur = nil
        var lower = canvas.clip
        lower.id = UUID()
        lower.effects = ImageEffects(solidBackground: .init(color: .init(red: 0, green: 1, blue: 0)))
        try canvas.draw([(lower, 0), (clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(96, 54)[1], 250, "透明領域は下段を保持する")
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
        var clip = VisualClip(assetID: nil, start: 0, end: features.duration, audioModulations: [:], effects:
            ImageEffects(solidBackground: .init(color: .init(red: 0.6, green: 0.6, blue: 0.6)), binarization: .init()))
        _ = clip.setKey(.binarizationThreshold, at: 0, value: 20)
        _ = clip.setKey(.binarizationThreshold, at: 0.2, value: 80)
        track.layers[0].clips = [clip]
        let output = directory.appendingPathComponent("binarization.mp4")
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
        XCTAssertEqual(index, Int64(ceil(features.duration * 30)))
        XCTAssertEqual(reader.status, .completed)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (frame, high) in [(0, true), (6, false)] {
            let image = try generator.copyCGImage(at: CMTime(value: Int64(frame), timescale: 30), actualTime: nil)
            let context = try XCTUnwrap(CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                                space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[(540 * 1920 + 960) * 4]
            if high { XCTAssertGreaterThan(pixel, 245) } else { XCTAssertLessThan(pixel, 10) }
        }
    }

    @MainActor func testDeletionUndoAndProjectStorage() throws {
        _ = NSApplication.shared
        let editor = VisualEditor(); _ = editor.view
        editor.duration = 4; editor.currentTime = 1; editor.setAvailable(true)
        var clip = VisualClip(assetID: nil, start: 0, end: 4, audioModulations: [:], effects: ImageEffects(binarization: .init()))
        _ = clip.setKey(.binarizationThreshold, at: 0, value: 30)
        clip.audioModulations[.binarizationAmount] = AudioModulation(source: .beat, amount: -20)
        clip.automationRanges[.binarizationAmount] = .init(lower: 20, upper: 100)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        editor.commit(track, selectedID: clip.id)
        let history = EditHistory()
        history.reset(EditSnapshot(visuals: track))
        var commits = 0
        editor.onChange = { value in commits += 1; history.record(EditSnapshot(visuals: value)) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let effects = try XCTUnwrap(all(editor.view).compactMap { $0 as? ImageEffectsEditor }.first)
        let controls = all(effects).compactMap { $0 as? NSButton }
        let swap = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "visuals.effects.binarization.swap" })
        XCTAssertTrue(swap.sendAction(swap.action, to: swap.target))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertEqual(history.redo()?.visuals, editor.track)
        let remove = try XCTUnwrap(controls.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        let deleted = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertNil(deleted.effects?.binarization)
        XCTAssertNil(deleted.curve(.binarizationThreshold))
        XCTAssertNil(deleted.audioModulations[.binarizationAmount])
        XCTAssertNil(deleted.automationRanges[.binarizationAmount])
        let restored = try XCTUnwrap(history.undo()?.visuals)
        XCTAssertNotNil(restored.clip(clip.id)?.effects?.binarization)
        XCTAssertEqual(restored.clip(clip.id)?.curves, clip.curves)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "BinarizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectStorage(defaults: defaults)
        let audio = directory.appendingPathComponent("tone.wav")
        let url = ProjectStorage.projectURL(for: audio)
        try storage.save(ProjectFile(audioURL: audio, visuals: restored, settings: SceneSettings(), projectURL: url), to: url)
        XCTAssertEqual(try storage.read(from: url).visuals, restored)
    }

    @MainActor func testEditorActionsAndCommonNumericControls() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
        var commits = 0
        editor.load(clip, editable: true)
        editor.onCommit = { clip.effects = $0; commits += 1; editor.load(clip, editable: true) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "2値化"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(clip.effects?.binarization, .init())
        for parameter in [ImageParameter.binarizationThreshold, .binarizationAmount] {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.defaultValue)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let swap = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "visuals.effects.binarization.swap" })
        let before = commits
        XCTAssertTrue(swap.sendAction(swap.action, to: swap.target))
        XCTAssertEqual(commits, before + 1)
        XCTAssertEqual(clip.effects?.binarization?.darkColor, RGBColor(red: 1, green: 1, blue: 1))
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.binarization?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.binarization)
    }
}
