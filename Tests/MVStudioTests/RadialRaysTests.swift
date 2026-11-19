import AppKit
import AVFoundation
import Metal
import XCTest
@testable import MVStudio

final class RadialRaysTests: XCTestCase {
    func testGeometryEllipseClockAndTrim() throws {
        let effect = ImageEffects.RadialRays(seed: 42)
        XCTAssertTrue(effect.isValid)
        let instances = effect.instances(at: 1.5)
        XCTAssertEqual(instances.count, 17)
        XCTAssertEqual(instances, effect.instances(at: 1.5))
        XCTAssertNotEqual(instances, effect.instances(at: 1.6))
        var still = effect; still.frequency = 0
        XCTAssertEqual(still.instances(at: -20), still.instances(at: 100))
        var fixed = effect; fixed.variation = 0; fixed.lengthVariation = 0; fixed.flicker = 0
        XCTAssertEqual(fixed.instances(at: 0), fixed.instances(at: 20))
        var more = effect; more.count = 128
        XCTAssertEqual(Array(more.instances(at: 1.5).prefix(16)), Array(instances.prefix(16)))
        var circle = fixed; circle.length = 500; circle.squash = 0
        let first = try XCTUnwrap(circle.instances(at: 0).first)
        XCTAssertEqual(Double(first.triangle.x), 500 * cos(2.5 * .pi / 180), accuracy: 0.001)
        XCTAssertEqual(Double(first.triangle.y), -500 * sin(2.5 * .pi / 180), accuracy: 0.001)
        var ellipse = circle; ellipse.length = 1000; ellipse.squash = 50
        XCTAssertEqual(Double(try XCTUnwrap(ellipse.instances(at: 0).first).triangle.x), Double(first.triangle.x) * 2, accuracy: 0.001)
        XCTAssertEqual(ellipse.instances(at: 0).last?.style.z, 60)
        XCTAssertEqual(ellipse.instances(at: 0).last?.style.w, 60)
        ellipse.fitAspectRatio(width: 1920, height: 1080)
        XCTAssertEqual(ellipse.length, 1000)
        XCTAssertEqual(ellipse.squash, 43.75)
        ellipse.length = 7680; ellipse.fitAspectRatio(width: 1080, height: 1920)
        XCTAssertEqual(ellipse.length, 7680)
        XCTAssertEqual(ellipse.radii.x / ellipse.radii.y, 1080.0 / 1920, accuracy: 1e-6)
        ellipse.length = 1; ellipse.fitAspectRatio(width: 1920, height: 1080)
        XCTAssertTrue(ellipse.isValid)
        XCTAssertEqual(ellipse.radii.x / ellipse.radii.y, 1920.0 / 1080, accuracy: 1e-6)
        for squash in [-99.0, -50, 0, 50, 99] {
            var shape = fixed; shape.length = 500; shape.squash = squash
            XCTAssertTrue(shape.isValid)
            let core = try XCTUnwrap(shape.instances(at: 0).last)
            XCTAssertEqual(core.style.z, 60)
            XCTAssertEqual(core.style.w, 60)
            XCTAssertEqual(max(shape.radii.x, shape.radii.y), 500)
            XCTAssertEqual(min(shape.radii.x, shape.radii.y), 500 * (1 - abs(squash) / 100), accuracy: 1e-6)
            XCTAssertTrue(shape.instances(at: 0).allSatisfy { ray in (0..<4).allSatisfy { ray.axis[$0].isFinite && ray.triangle[$0].isFinite } })
        }
        var invalidSquash = fixed; invalidSquash.squash = 100
        XCTAssertFalse(invalidSquash.isValid)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(effect)) as? [String: Any])
        XCTAssertEqual(json["length"] as? Double, 1440)
        XCTAssertEqual(json["squash"] as? Double, 43.75)
        XCTAssertNil(json["width"]); XCTAssertNil(json["height"])
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(radialRays: effect))
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.radialRays?.instances(at: 0.5), instances)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        for time in [-Double.greatestFiniteMagnitude, -1e200, -10, 0, 1e200, Double.greatestFiniteMagnitude] {
            for ray in effect.instances(at: time) {
                XCTAssertTrue((0..<4).allSatisfy { ray.axis[$0].isFinite && ray.bounds[$0].isFinite && ray.triangle[$0].isFinite })
            }
        }
        var maximum = effect; maximum.length = 7680
        XCTAssertTrue(maximum.isValid)
        XCTAssertEqual(try JSONDecoder().decode(ImageEffects.RadialRays.self, from: JSONEncoder().encode(maximum)), maximum)
        maximum.length = 7681; XCTAssertFalse(maximum.isValid)
        var invalid = effect; invalid.count = 1.5; XCTAssertFalse(invalid.isValid)
        invalid = effect; invalid.length = 0; XCTAssertFalse(invalid.isValid)
        invalid = effect; invalid.phaseOffset = .infinity; XCTAssertTrue(invalid.instances(at: 0).isEmpty)
        invalid = effect; invalid.glow = .nan; XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(effect.instances(at: .nan).isEmpty)
    }

    func testRotationVariationAndDeterministicFrameChanges() throws {
        let effect = ImageEffects.RadialRays(squash: 0, lengthVariation: 0, variation: 100, flicker: 0, coreSize: 0, seed: 42)
        func angle(_ ray: ImageEffects.RadialRays.Instance) -> Double { atan2(Double(ray.axis.w), Double(ray.axis.z)) }
        func delta(_ value: Double) -> Double { atan2(sin(value), cos(value)) }
        var firstAngles: [Double] = []
        for frame in 0..<20 {
            let time = Double(frame) / 15 + 0.001
            let rays = effect.instances(at: time)
            let first = try XCTUnwrap(rays.first)
            firstAngles.append(angle(first))
            XCTAssertEqual(rays, effect.instances(at: time + 0.01))
            for (index, ray) in rays.enumerated() {
                let base = Double(index) * 0.6180339887498949 * 2 * .pi
                let relative = delta(angle(ray) - base - angle(first))
                XCTAssertLessThanOrEqual(abs(relative), 16 * .pi / 180 + 1e-6)
            }
        }
        XCTAssertTrue(zip(firstAngles, firstAngles.dropFirst()).contains { abs(delta($1 - $0)) > .pi / 4 })
        XCTAssertEqual(effect.instances(at: 0.001), effect.instances(at: 0.001))
        var still = effect; still.frequency = 0
        XCTAssertEqual(still.instances(at: 0), still.instances(at: 100))
        var regular = effect; regular.variation = 0
        XCTAssertEqual(regular.instances(at: 0), regular.instances(at: 1))
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(radialRays: effect))
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.radialRays?.instances(at: 0.2), effect.instances(at: 1.2))
    }

    func testAutomationMusicAndPersistence() throws {
        var clip = VisualClip(assetID: nil, start: 0, end: 4, audioModulations: [:], effects: ImageEffects(radialRays: .init(seed: 42)))
        for parameter in ImageEffects.RadialRays.parameters {
            let range = parameter.defaultRange
            _ = clip.setKey(parameter, at: 0, value: range.lowerBound)
            _ = clip.setKey(parameter, at: 2, value: range.upperBound)
            let value = try XCTUnwrap(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 1))))
            let expected = (range.lowerBound + range.upperBound) / 2
            XCTAssertEqual(value, parameter == .raysCount ? expected.rounded() : expected, accuracy: 1e-6)
        }
        var track = VisualTrack(); track.layers[0].clips = [clip]
        try track.validate(duration: 4)
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/song.wav"), visuals: track, settings: SceneSettings(), projectURL: URL(fileURLWithPath: "/tmp/test.mvproject"))
        let restored = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        try restored.validate(); XCTAssertEqual(restored.visuals, track)
        var synced = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:], effects: ImageEffects(radialRays: .init(opacity: 0, seed: 42)))
        synced.audioModulations[.raysOpacity] = AudioModulation(source: .beat, amount: 100)
        XCTAssertEqual(synced.evaluatedEffects(at: 0)?.radialRays?.opacity, 100)
        XCTAssertEqual(synced.evaluatedEffects(at: 0.3)?.radialRays?.opacity, 0)
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{\"nodes\":[],\"isBypassed\":false}".utf8)).radialRays)
    }

    func testAdditiveCoreGlowScaleAndMask() throws {
        let canvas = try EffectTestCanvas()
        let half = try EffectTestCanvas(scale: 0.5)
        var clip = canvas.clip
        var rays = ImageEffects.RadialRays(length: 500, squash: 0, count: 1, thickness: 5, lengthVariation: 0, variation: 0, flicker: 0, glow: 0, coreSize: 0, frequency: 0, seed: 42)
        clip.effects = ImageEffects(radialRays: rays)
        try canvas.draw([])
        let background = canvas.pixel(1200, 540)
        let empty = canvas.pixel(1200, 700)
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(1200, 540)[0], 240)
        XCTAssertEqual(canvas.pixel(1200, 540)[3], background[3])
        XCTAssertEqual(canvas.pixel(1200, 700), empty)
        try half.draw([(clip, 1)])
        XCTAssertGreaterThan(half.pixel(600, 270)[0], 230)
        let outside = canvas.pixel(1200, 560)[0]
        rays.glow = 30; clip.effects?.radialRays = rays
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(1200, 560)[0], outside + 5)
        rays.coreSize = 120; clip.effects?.radialRays = rays
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(960, 540)[2], 245)
        var upper = canvas.clip; upper.id = UUID()
        upper.effects = ImageEffects(belowMask: .init(geometry: ShapeGeometry(width: 0)))
        try canvas.draw([(clip, 1), (upper, 2)])
        XCTAssertEqual(canvas.pixel(1200, 540), background)
        for disabled in [0, 1, 2, 3] {
            var off = clip
            if disabled == 0 { off.fixedValues[.opacity] = 0 }
            if disabled == 1 { off.effects?.radialRays?.opacity = 0 }
            if disabled == 2 { off.effects?.radialRays?.intensity = 0 }
            if disabled == 3 { off.effects?.radialRays?.isEnabled = false }
            try canvas.draw([(off, 1)])
            XCTAssertEqual(canvas.pixel(1200, 540), background)
        }
        rays.length = 100; rays.coreSize = 0; rays.glow = 0
        clip.effects = ImageEffects(radialRays: rays)
        try canvas.draw([(clip, 1)])
        XCTAssertEqual(canvas.pixel(1200, 540), background)
        rays.length = 500; rays.coreSize = 120
        clip.effects?.radialRays = rays
        try canvas.draw([(clip, 1)])
        let roundCore = canvas.pixel(960, 580)[0]
        for squash in [-99.0, -50, 50, 99] {
            clip.effects?.radialRays?.squash = squash
            try canvas.draw([(clip, 1)])
            XCTAssertEqual(canvas.pixel(960, 580)[0], roundCore)
        }
        clip.effects = ImageEffects(radialRays: .init(seed: 42))
        try canvas.draw([(clip, 1)], time: 0.5)
        try canvas.save("/tmp/my-movie-rays-default.png")
        clip.effects?.radialRays?.count = 128; clip.effects?.radialRays?.glow = 100
        var second = clip; second.id = UUID()
        var third = clip; third.id = UUID()
        try canvas.draw([(clip, 0), (second, 1), (third, 2)])
        print("RAYS_MAX_THREE_LAYERS gpu_ms=\(canvas.lastGPUMS)")
    }

    @MainActor
    func testEditorFieldsColorFitShuffleAndRemoval() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
        func load() { editor.load(clip, editable: true) }
        load(); editor.onCommit = { clip.effects = $0; load() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let add = try XCTUnwrap(all(editor).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "放射光線"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.radialRays); XCTAssertFalse(try XCTUnwrap(add.menu?.effectItem(titled: item.title + "（追加済み）")).isEnabled)
        let fields = all(editor).compactMap { $0 as? DragValueField }
        for parameter in ImageEffects.RadialRays.parameters {
            let field = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertNotNil(field.onCreateAutomation); XCTAssertNotNil(field.onEditMusic)
        }
        let length = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.raysLength" })
        XCTAssertEqual(length.doubleValue, 144)
        XCTAssertEqual(length.knobRange, 0.1...768)
        length.stringValue = "768"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: length))
        XCTAssertEqual(clip.effects?.radialRays?.length, 7680)
        length.stringValue = "999"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: length))
        XCTAssertEqual(clip.effects?.radialRays?.length, 7680)
        length.stringValue = "200"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: length))
        XCTAssertEqual(clip.effects?.radialRays?.length, 2000)
        XCTAssertTrue(length.onDragStart?() == true); length.onDragChange?(3); length.onDragEnd?()
        XCTAssertEqual(clip.effects?.radialRays?.length, 2030)
        XCTAssertTrue(length.onDragStart?() == true); length.onDragChange?(20); XCTAssertTrue(length.cancelNumberDrag())
        XCTAssertEqual(clip.effects?.radialRays?.length, 2030)
        XCTAssertEqual(length.doubleValue, 203)
        let fit = try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.title == "画面比率に合わせる" })
        XCTAssertTrue(fit.sendAction(fit.action, to: fit.target))
        XCTAssertEqual(clip.effects?.radialRays?.squash, 43.75)
        length.onReset?(); XCTAssertEqual(clip.effects?.radialRays?.length, 1440)
        XCTAssertEqual(length.doubleValue, 144)
        let squash = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.raysSquash" })
        squash.stringValue = "-50"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: squash))
        XCTAssertEqual(clip.effects?.radialRays?.squash, -50)
        XCTAssertEqual(clip.effects?.radialRays?.length, 1440)
        XCTAssertTrue(squash.onDragStart?() == true); squash.onDragChange?(3); squash.onDragEnd?()
        XCTAssertEqual(clip.effects?.radialRays?.squash, -49.25)
        squash.onReset?(); XCTAssertEqual(clip.effects?.radialRays?.squash, 43.75)
        let color = try XCTUnwrap(all(editor).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.raysColor" })
        color.activate(true); NSColorPanel.shared.color = .red
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(clip.effects?.radialRays?.color, RGBColor(red: 1, green: 0, blue: 0))
        color.deactivate(); NSColorPanel.shared.orderOut(nil)
        let shuffle = try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.title == "配置を変更" && !$0.superview!.isHidden && $0.action == NSSelectorFromString("shuffleRays") })
        let seed = clip.effects?.radialRays?.seed
        XCTAssertTrue(shuffle.sendAction(shuffle.action, to: shuffle.target))
        XCTAssertNotEqual(clip.effects?.radialRays?.seed, seed)
        let remove = try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target)); XCTAssertNil(clip.effects?.radialRays)
    }
    @MainActor
    func testEditorDeletionCleansAutomationAndHistoryRestoresIt() throws {
        _ = NSApplication.shared
        let editor = VisualEditor()
        _ = editor.view
        let timeline = TimelineView(frame: .zero)
        editor.timeline = timeline; editor.duration = 10; editor.setAvailable(true)
        var clip = VisualClip(assetID: nil, start: 0, end: 4, audioModulations: [:], effects: ImageEffects(radialRays: .init(seed: 42)))
        _ = clip.setKey(.raysIntensity, at: 0, value: 100)
        _ = clip.setKey(.raysIntensity, at: 2, value: 200)
        clip.audioModulations[.raysIntensity] = AudioModulation(source: .beat, amount: 10)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        editor.load(track, projectURL: nil)
        timeline.onImageSelect?(clip.id, timeline.visuals.layers[0].id)
        let history = EditHistory()
        let original = EditSnapshot(visuals: track)
        history.reset(original)
        editor.onChange = { history.record(EditSnapshot(visuals: $0)) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let length = try XCTUnwrap(all(editor.view).compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value.raysLength" })
        length.onReset?()
        let effectEditor = try XCTUnwrap(all(editor.view).compactMap { $0 as? ImageEffectsEditor }.first)
        let remove = try XCTUnwrap(all(effectEditor).compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        let removed = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertNil(removed.effects?.radialRays)
        XCTAssertNil(removed.curve(.raysIntensity))
        XCTAssertNil(removed.audioModulations[.raysIntensity])
        XCTAssertNil(removed.automationRanges[.raysIntensity])
        let undone = try XCTUnwrap(history.undo())
        XCTAssertEqual(undone, original)
        editor.restore(undone.visuals)
        XCTAssertEqual(editor.track, track)
        let redone = try XCTUnwrap(history.redo())
        editor.restore(redone.visuals)
        XCTAssertNil(editor.track.clip(clip.id)?.effects?.radialRays)
    }

    func testMaximumThreeLayersForSixtySeconds() throws {
        let canvas = try EffectTestCanvas()
        let clip = VisualClip(assetID: nil, start: 0, end: 60, audioModulations: [:], effects: ImageEffects(radialRays: .init(length: 7680, count: 128, glow: 100, seed: 42)))
        var second = clip; second.id = UUID()
        var third = clip; third.id = UUID()
        var samples: [Double] = []
        for frame in 0..<1800 {
            try autoreleasepool {
                try canvas.draw([(clip, 0), (second, 1), (third, 2)], time: Double(frame) / 30)
                samples.append(canvas.lastGPUMS)
            }
        }
        samples.sort()
        print("RAYS_60_SECONDS frames=1800 gpu_p95_ms=\(samples[1710]) gpu_max_ms=\(samples.last!)")
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
        let focus = ImageEffects.RadialRays(frequency: 0, seed: 42)
        track.layers[0].clips = [VisualClip(assetID: nil, start: 0, end: 0.3, audioModulations: [:], effects: ImageEffects(radialRays: focus))]
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
        let x = 960
        let y = 540
        XCTAssertGreaterThan(bytes[(y * 1920 + x) * 4], 230)
    }

}
