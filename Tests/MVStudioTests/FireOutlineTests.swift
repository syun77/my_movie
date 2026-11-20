import AppKit
import AVFoundation
import Darwin
import XCTest
@testable import MVStudio

final class FireOutlineTests: XCTestCase {
    typealias Fire = ImageEffects.FireOutline

    func testValidationAutomationPersistenceAndTrim() throws {
        XCTAssertEqual(EffectKind.sobelChromatic.rawValue, 26)
        XCTAssertEqual(EffectKind.fireOutline.rawValue, 27)
        XCTAssertEqual(Fire.parameters.count, 10)
        var clip = VisualClip(start: 1, end: 5, effects: ImageEffects(fireOutline: .init()))
        for field in Fire.fields {
            let parameter = field.parameter
            let definition = try XCTUnwrap(parameter.effect)
            XCTAssertEqual(definition.range, field.range)
            XCTAssertEqual(parameter.effectKind, .fireOutline)
            XCTAssertEqual(clip.baseValue(parameter), Fire()[keyPath: field.path])
            _ = clip.setKey(parameter, at: 1, value: field.range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: field.range.upperBound)
            let result = try XCTUnwrap(clip.evaluatedEffects(at: 2)?.fireOutline)
            XCTAssertEqual(result[keyPath: field.path], (field.range.lowerBound + field.range.upperBound) / 2, accuracy: 1e-8)
            for value in [Double.nan, .infinity, field.range.upperBound + 1, field.range.lowerBound - 1] {
                var invalid = Fire(); invalid[keyPath: field.path] = value
                XCTAssertFalse(invalid.isValid, field.title)
                XCTAssertFalse(ImageEffects(fireOutline: invalid).isValid)
            }
        }
        let before = try XCTUnwrap(clip.evaluatedEffects(at: 3)?.fireOutline)
        clip.trimStart(to: 2)
        let after = try XCTUnwrap(clip.evaluatedEffects(at: 3)?.fireOutline)
        XCTAssertEqual(before.clock(at: 2), after.clock(at: 1))
        XCTAssertEqual(before.x, after.x)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        var invalid = Fire(); invalid.phaseOffset = .infinity
        XCTAssertFalse(invalid.isValid)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let url = URL(fileURLWithPath: "/tmp/fire.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/tone.wav"), visuals: track,
                                  settings: SceneSettings(), projectURL: url)
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try ProjectMigrator.read(data, at: url).project.visuals, track)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["version"] = 14
        XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root), at: url))
    }

    func testRenderingGeometryClockVisibilityAndCache() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(fireOutline: Fire(x: 700, y: 400, width: 1000, height: 600))
        let points = stride(from: 0, to: 270, by: 9).flatMap { y in stride(from: 0, to: 480, by: 9).map { ($0, y) } }
        func pixels() -> [[UInt8]] { points.map { canvas.pixel($0.0, $0.1) } }
        try canvas.draw([])
        let unlit = [(10, 10), (400, 100), (175, 100)].map { canvas.pixel($0.0, $0.1) }
        try canvas.draw([(clip, 1)], time: 0.5)
        let original = pixels()
        XCTAssertTrue(original.contains { $0[0] > 80 && $0[0] > $0[1] + 30 }, "紫系の炎")
        for (index, point) in [(10, 10), (400, 100), (175, 100)].enumerated() {
            XCTAssertEqual(canvas.pixel(point.0, point.1), unlit[index], "矩形外と中央は透明")
        }
        try canvas.save("/tmp/my-movie-fire-outline-preview.png")
        try canvas.draw([(clip, 1)], time: 1.4)
        XCTAssertNotEqual(original, pixels())
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(original, pixels())
        clip.trimStart(to: 0.25)
        try canvas.draw([(clip, 1)], time: 0.5)
        XCTAssertEqual(original, pixels())
        clip.effects?.fireOutline?.speed = 0
        try canvas.draw([(clip, 1)], time: 0.5); let still = pixels()
        try canvas.draw([(clip, 1)], time: 1.5); XCTAssertEqual(still, pixels())
        clip.effects?.fireOutline?.hue = 180
        try canvas.draw([(clip, 1)]); XCTAssertNotEqual(still, pixels())
        let enabled = try XCTUnwrap(clip.effects?.fireOutline)
        clip.effects = nil
        try canvas.draw([(clip, 1)]); let hidden = pixels()
        for change in [\Fire.opacity, \.brightness, \.spread] {
            var zero = enabled; zero[keyPath: change] = 0
            clip.effects = ImageEffects(fireOutline: zero)
            try canvas.draw([(clip, 1)]); XCTAssertEqual(hidden, pixels())
        }
        clip.effects = ImageEffects(fireOutline: enabled); clip.effects?.fireOutline?.isEnabled = false
        try canvas.draw([(clip, 1)]); XCTAssertEqual(hidden, pixels())
        clip.effects?.fireOutline?.isEnabled = true; clip.effects?.isBypassed = true
        try canvas.draw([(clip, 1)]); XCTAssertEqual(hidden, pixels())
        clip.effects?.isBypassed = false; clip.fixedValues[.opacity] = 0
        try canvas.draw([(clip, 1)]); XCTAssertEqual(hidden, pixels())
        clip.fixedValues[.opacity] = 100; clip.effects?.fireOutline?.x = -1500
        try canvas.draw([(clip, 1)]); XCTAssertEqual(hidden, pixels())
    }

    func testAdditiveCompositionChainOrderMasksAndPadding() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var background = canvas.clip
        background.effects = ImageEffects(solidBackground: .init(color: .init(red: 0.3, green: 0.2, blue: 0.1)))
        var clip = VisualClip(start: 0, end: 2, effects: ImageEffects(fireOutline: .init()))
        let points = [(5, 50), (80, 5), (100, 80), (240, 135), (475, 200)]
        func pixels() -> [[UInt8]] { points.map { canvas.pixel($0.0, $0.1) } }
        try canvas.draw([]); let unlitCenter = canvas.pixel(240, 135)
        try canvas.draw([(background, 1)]); let base = pixels()
        try canvas.draw([(background, 1), (clip, 2)]); let lit = pixels()
        XCTAssertTrue(zip(base, lit).allSatisfy { a, b in (0..<3).allSatisfy { b[$0] >= a[$0] } })
        XCTAssertTrue(zip(base, lit).contains { $1[0] > $0[0] + 20 })
        clip.effects?.colorCorrection = .init(hue: 100)
        try canvas.draw([(background, 1), (clip, 2)]); XCTAssertNotEqual(lit, pixels(), "alpha0の光も後段色補正")
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(background, 1), (clip, 2)]); XCTAssertEqual(base, pixels())
        let maskID = try XCTUnwrap(clip.effects?.nodes.last?.id)
        clip.effects?.move(maskID, to: 0)
        try canvas.draw([(background, 1), (clip, 2)]); XCTAssertNotEqual(base, pixels(), "先行マスクは後の生成に無作用")
        var owner = VisualClip(start: 0, end: 2, effects: ImageEffects(belowMask: .init(geometry: ShapeGeometry(width: 0))))
        try canvas.draw([(background, 1), (clip, 2), (owner, 3)]); XCTAssertEqual(base, pixels())
        owner.fixedValues[.opacity] = 0
        try canvas.draw([(background, 1), (clip, 2), (owner, 3)]); XCTAssertNotEqual(base, pixels())
        clip.effects = ImageEffects(blur: .init(radius: 5), fireOutline: .init())
        try canvas.draw([(clip, 1)]); let before = pixels()
        let blurID = try XCTUnwrap(clip.effects?.nodes.first?.id)
        clip.effects?.move(blurID, to: 1)
        try canvas.draw([(clip, 1)]); XCTAssertNotEqual(before, pixels())
        XCTAssertEqual(canvas.pixel(240, 135), unlitCenter)
    }

    func testExtremeRectanglesAndUniformsRemainFinite() throws {
        let canvas = try EffectTestCanvas(scale: 0.125)
        for fire in [Fire(width: 1, height: 1), Fire(width: 7680, height: 4320, spread: 400, detail: 400, speed: 400),
                     Fire(x: -1920, y: -1080, width: 7680, height: 4320, spread: 0.00001, detail: 25, hue: -180)] {
            XCTAssertTrue(fire.isValid)
            var effect = fire; effect.phaseOffset = -999999
            let u = effect.uniforms(at: 2, scale: 0.125, opacity: 1)
            for vector in [u.rectangle, u.pattern, u.output] { for n in 0..<4 { XCTAssertTrue(vector[n].isFinite) } }
            try canvas.draw([(VisualClip(start: 0, end: 3, effects: ImageEffects(fireOutline: effect)), 1)])
        }
    }

    @MainActor func testEditorAndPositionTransaction() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(start: 0, end: 4)
        var commits = 0
        editor.onCommit = { clip.effects = $0; commits += 1; editor.load(clip, editable: true) }
        editor.load(clip, editable: true)
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "炎アウトライン"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(commits, 1); XCTAssertNotNil(clip.effects?.fireOutline)
        for parameter in Fire.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.defaultValue)
            XCTAssertNotNil(field.onCreateAutomation); XCTAssertNotNil(field.onEditMusic)
        }
        let visuals = VisualEditor(); _ = visuals.view
        visuals.duration = 10; visuals.currentTime = 1; visuals.setAvailable(true)
        _ = clip.setKey(.fireX, at: 0, value: 960)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        visuals.commit(track, selectedID: clip.id)
        let history = EditHistory(); history.reset(EditSnapshot(visuals: track))
        var positionCommits = 0
        visuals.onChange = { positionCommits += 1; history.record(EditSnapshot(visuals: $0)) }
        let target = try XCTUnwrap(visuals.previewHandleTarget(for: .fireY))
        let edit = try XCTUnwrap(target.begin()); edit.update(CGPoint(x: 1100, y: 650))
        XCTAssertEqual(positionCommits, 0); edit.finish(true)
        XCTAssertEqual(positionCommits, 1)
        XCTAssertEqual(visuals.track.clip(clip.id)?.curve(.fireX)?.keys.first?.value, 1100)
        XCTAssertEqual(history.undo()?.visuals, track)
        let cancel = try XCTUnwrap(target.begin()); cancel.update(.zero); cancel.finish(false)
        XCTAssertEqual(positionCommits, 1)
        XCTAssertTrue(try XCTUnwrap(PreviewPositionPair.containing(.fireX)).enabled(try XCTUnwrap(clip.effects)))
        let speed = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value.fireSpeed" })
        speed.doubleValue = 150
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: speed))
        XCTAssertEqual(clip.effects?.fireOutline?.speed, 150)
        let beforeDrag = commits
        XCTAssertTrue(speed.onDragStart?() == true)
        speed.onDragChange?(12)
        XCTAssertEqual(commits, beforeDrag)
        speed.onDragEnd?()
        XCTAssertEqual(commits, beforeDrag + 1)
        XCTAssertEqual(clip.effects?.fireOutline?.speed, 162)
        XCTAssertTrue(speed.onDragStart?() == true)
        speed.onDragChange?(20)
        XCTAssertTrue(speed.cancelNumberDrag())
        XCTAssertEqual(clip.effects?.fireOutline?.speed, 162)
        speed.onReset?()
        XCTAssertEqual(clip.effects?.fireOutline?.speed, 100)
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off; XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertFalse(try XCTUnwrap(clip.effects?.fireOutline).isEnabled)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.fireOutline)
        XCTAssertNil(clip.curve(.fireX))
    }

    @MainActor func testMusicDuplicationAndNodeOwnership() throws {
        _ = NSApplication.shared
        var clip = VisualClip(start: 0, end: 2, effects: ImageEffects(fireOutline: .init()))
        clip.audioModulations[.fireSpread] = AudioModulation(source: .beat, amount: 20)
        XCTAssertEqual(clip.evaluatedEffects(at: 0, settings: SceneSettings(bpm: 120))?.fireOutline?.spread, 120)
        _ = clip.setKey(.fireWidth, at: 0, value: 1000)
        _ = clip.setKey(.fireWidth, at: 1, value: 1800)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let editor = PlacementEditor(); _ = editor.view
        editor.duration = 10; editor.restoreTab(.visuals); editor.setAvailable(hasAudio: true, isBusy: false)
        editor.visuals.load(track, projectURL: URL(fileURLWithPath: "/tmp/fire-copy/project.mvproject"))
        editor.timeline.onImageSelect?(clip.id, track.layers[0].id)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        editor.editClip(.copy, pasteboard: pasteboard); editor.editClip(.duplicate, pasteboard: pasteboard)
        let duplicate = try XCTUnwrap(editor.visuals.track.clips.last)
        XCTAssertEqual(duplicate.start, 2)
        XCTAssertEqual(duplicate.effects?.fireOutline, clip.effects?.fireOutline)
        XCTAssertNotEqual(duplicate.effects?.nodes.first?.id, clip.effects?.nodes.first?.id)
        XCTAssertNotEqual(duplicate.curve(.fireWidth)?.keys.first?.id, clip.curve(.fireWidth)?.keys.first?.id)
        XCTAssertEqual(duplicate.audioModulations, clip.audioModulations)
    }

    func testMP4MatchesCommonRenderer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 14400))
        pcm.frameLength = 14400
        for index in 0..<14400 { pcm.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 48000)) * 0.1 }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        let clip = VisualClip(start: 0, end: 0.3, effects: ImageEffects(fireOutline: .init()))
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let features = try AudioAnalyzer.analyze(url: audio)
        let output = directory.appendingPathComponent("fire.mp4")
        try await VideoExporter.export(visuals: track, projectURL: ProjectStorage.projectURL(for: audio), audioURL: audio,
                                       features: features, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(),
                                       destination: output, cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let videos = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audios.count, 1); XCTAssertEqual(videos.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: try XCTUnwrap(videos.first),
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let canvas = try EffectTestCanvas()
        var count = 0
        while let sample = decoded.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            XCTAssertEqual(time, Double(count) / 30, accuracy: 1e-6)
            try canvas.draw([(clip, 0)], time: time, video: true)
            let buffer = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for (x, y) in [(30, 500), (900, 30), (1890, 700), (700, 1050), (960, 540)] {
                let expected = canvas.pixel(x, y)
                for channel in 0..<3 {
                    XCTAssertEqual(Double(base[y * stride + x * 4 + channel]), Double(expected[channel]), accuracy: 18,
                                   "frame \(count) at \(x),\(y)")
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, Int(ceil(features.duration * 30)))
    }

    func test1080pLayerCost() throws {
        let canvas = try EffectTestCanvas()
        for count in [1, 3, 50] {
            let clips = (0..<count).map { (VisualClip(start: 0, end: 3, effects: ImageEffects(fireOutline: .init())), $0) }
            var maximum = 0.0
            for frame in 0..<3 {
                try canvas.draw(clips, time: 0.2 + Double(frame) / 30)
                maximum = max(maximum, canvas.lastGPUMS)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("Fire outline 1080p \(count) layers GPU max \(maximum)ms, peak RSS \(usage.ru_maxrss) bytes")
            XCTAssertGreaterThan(maximum, 0)
        }
    }
}
