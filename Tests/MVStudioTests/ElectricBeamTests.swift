import AppKit
import AVFoundation
import Darwin
import Metal
import XCTest
@testable import MVStudio

final class ElectricBeamTests: XCTestCase {
    typealias Beam = ImageEffects.ElectricBeam

    func testBoundedGeometryClockAndTrim() throws {
        var beam = Beam(seed: 17)
        func paths(_ time: Double) -> [[ElectricBeamGeometry.Segment]] {
            ElectricBeamGeometry.paths(.init(beam, at: time))
        }
        let original = paths(0.501)
        XCTAssertEqual(original.count, 6)
        XCTAssertTrue(original.allSatisfy { $0.count == 20 })
        XCTAssertEqual(original, paths(0.51))
        XCTAssertNotEqual(original, paths(0.55))
        XCTAssertEqual(original, paths(0.501))
        XCTAssertNotEqual(paths(-0.01), paths(0))
        beam.speed = 0
        XCTAssertEqual(paths(-900), paths(900))
        beam.length = 7680; beam.width = 40; beam.bend = 400; beam.spread = 1080; beam.speed = 400
        XCTAssertEqual(paths(3).flatMap { $0 }.count, 384)
        for segment in paths(-9999).flatMap({ $0 }) {
            for index in 0..<4 { XCTAssertTrue(segment.endpoints[index].isFinite) }
            XCTAssertGreaterThan(segment.widths.x, 0)
            XCTAssertLessThanOrEqual(segment.widths.x, 20)
        }
        beam.length = 1; beam.count = 1; beam.spread = 0; beam.bend = 0; beam.angle = 0
        let straight = try XCTUnwrap(paths(0).first)
        XCTAssertEqual(straight.count, 8)
        XCTAssertEqual(straight.first?.endpoints.x, 959.5)
        XCTAssertEqual(straight.last?.endpoints.z, 960.5)
        XCTAssertTrue(straight.allSatisfy { $0.endpoints.y == 540 && $0.endpoints.w == 540 })
        var clip = VisualClip(start: 1, end: 5, effects: ImageEffects(electricBeam: .init(seed: 7)))
        let before = try XCTUnwrap(clip.effects?.electricBeam)
        clip.trimStart(to: 2)
        let after = try XCTUnwrap(clip.effects?.electricBeam)
        XCTAssertEqual(ElectricBeamGeometry.paths(.init(before, at: 2)), ElectricBeamGeometry.paths(.init(after, at: 1)))
        XCTAssertEqual(after.seed, 7)
    }

    func testValidationAutomationAndVersionBoundary() throws {
        XCTAssertEqual(EffectKind.electricBeam.rawValue, 28)
        var clip = VisualClip(start: 0, end: 4, effects: ImageEffects(electricBeam: .init(seed: 9)))
        for field in Beam.fields {
            let parameter = field.parameter
            XCTAssertEqual(parameter.effectKind, .electricBeam)
            XCTAssertEqual(parameter.defaultValue, Beam(seed: 0)[keyPath: field.path])
            _ = clip.setKey(parameter, at: 0, value: field.range.lowerBound)
            _ = clip.setKey(parameter, at: 2, value: field.range.upperBound)
            let midpoint = (field.range.lowerBound + field.range.upperBound) / 2
            let value = try XCTUnwrap(clip.evaluatedEffects(at: 1)?.electricBeam)[keyPath: field.path]
            XCTAssertEqual(value, parameter == .beamCount ? midpoint.rounded() : midpoint, accuracy: 1e-6)
            for n in [Double.nan, .infinity, field.range.lowerBound-1, field.range.upperBound+1] {
                var bad = Beam(seed: 0); bad[keyPath: field.path] = n
                XCTAssertFalse(ImageEffects(electricBeam: bad).isValid)
            }
        }
        clip.audioModulations[.beamBrightness] = AudioModulation(source: .beat, amount: 30)
        XCTAssertEqual(clip.evaluatedEffects(at: 0, settings: SceneSettings(bpm: 120))?.electricBeam?.brightness, 30)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let url = URL(fileURLWithPath: "/tmp/beam.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), visuals: track, settings: SceneSettings(), projectURL: url)
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try ProjectMigrator.read(data, at: url).project.visuals, track)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); root["version"] = 15
        XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root), at: url))
        var invalid = Beam(seed: 0); invalid.phaseOffset = .infinity; XCTAssertFalse(invalid.isValid)
        invalid = Beam(seed: 0); invalid.color.red = .nan; XCTAssertFalse(invalid.isValid)
    }

    func testRenderingClockOrientationAndVisibility() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = VisualClip(start: 0, end: 3, effects: ImageEffects(electricBeam: .init(x: 960, y: 300, angle: 0, length: 1000, seed: 4)))
        let points = stride(from: 0, to: 270, by: 3).flatMap { y in stride(from: 0, to: 480, by: 3).map { ($0,y) } }
        func pixels() -> [[UInt8]] { points.map { canvas.pixel($0.0,$0.1) } }
        try canvas.draw([]); let empty = pixels()
        try canvas.draw([(clip,1)], time: 0.501); let visible = pixels()
        XCTAssertNotEqual(empty, visible)
        XCTAssertTrue(points.enumerated().contains { index, point in point.1 < 135 && visible[index][0] > empty[index][0] + 30 })
        XCTAssertEqual(canvas.pixel(240,240), empty[points.firstIndex(where: { $0 == (240,240) })!])
        try canvas.save("/tmp/my-movie-beam-preview.png")
        try canvas.draw([(clip,1)], time: 0.51); XCTAssertEqual(visible,pixels())
        try canvas.draw([(clip,1)], time: 1.4); XCTAssertNotEqual(visible,pixels())
        try canvas.draw([(clip,1)], time: 0.501); XCTAssertEqual(visible,pixels())
        clip.trimStart(to: 0.25)
        try canvas.draw([(clip,1)], time: 0.501); XCTAssertEqual(visible,pixels())
        clip.effects?.electricBeam?.speed = 0
        try canvas.draw([(clip,1)], time: 1); let frozen = pixels()
        try canvas.draw([(clip,1)], time: 2); XCTAssertEqual(frozen,pixels())
        for action in 0..<4 {
            clip.effects = ImageEffects(electricBeam: .init(seed: 4)); clip.fixedValues[.opacity] = 100
            switch action {
            case 0: clip.effects?.electricBeam?.brightness = 0
            case 1: clip.effects?.electricBeam?.isEnabled = false
            case 2: clip.effects?.isBypassed = true
            default: clip.fixedValues[.opacity] = 0
            }
            try canvas.draw([(clip,1)]); XCTAssertEqual(empty,pixels())
        }
    }

    func testContinuousStraightPathUnionAndAdditiveComposition() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        let beam = Beam(x: 960, y: 400, angle: 0, length: 1200, spread: 0, count: 1, width: 16, bend: 0, glowRadius: 40, brightness: 30, seed: 0)
        var clip = VisualClip(start: 0, end: 2, effects: ImageEffects(electricBeam: beam))
        let scan = (100..<380).map { ($0,100) }
        func pixels() -> [[UInt8]] { scan.map { canvas.pixel($0.0,$0.1) } }
        try canvas.draw([(clip,1)]); let path = pixels()
        for channel in 0..<3 {
            let values = path.map { Int($0[channel]) }
            XCTAssertLessThanOrEqual(values.max()! - values.min()!, 2, "継ぎ目で輝度が増えない")
        }
        var background = canvas.clip; background.effects = ImageEffects(solidBackground: .init(color: .init(red: 0.2, green: 0.1, blue: 0.05)))
        try canvas.draw([(background,0)]); let base = pixels(); let offPath = canvas.pixel(240,220)
        try canvas.draw([(background,0),(clip,1)])
        XCTAssertEqual(canvas.pixel(240,220),offPath)
        XCTAssertTrue(zip(base,pixels()).allSatisfy { a,b in (0..<3).allSatisfy { b[$0] >= a[$0] } })
        clip.effects?.colorCorrection = .init(hue: 120)
        try canvas.draw([(clip,1)]); XCTAssertNotEqual(path,pixels(), "alpha0の光も加工")
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(background,0),(clip,1)]); XCTAssertEqual(base,pixels())
        let maskID = try XCTUnwrap(clip.effects?.nodes.last?.id)
        clip.effects?.move(maskID, to: 0)
        try canvas.draw([(background,0),(clip,1)]); XCTAssertNotEqual(base,pixels())
        clip.effects = ImageEffects(blur: .init(radius: 12), electricBeam: beam)
        try canvas.draw([(clip,1)]); let beforeBlur = pixels()
        let blurID = try XCTUnwrap(clip.effects?.nodes.first?.id)
        clip.effects?.move(blurID, to: 1)
        try canvas.draw([(clip,1)]); XCTAssertNotEqual(beforeBlur,pixels())
        // Offscreen emission must remain available to a later blur.
        clip.effects = ImageEffects(electricBeam: Beam(x: 960,y: -20,angle: 0,length: 1800,spread: 0,count: 1,width: 8,bend: 0,glowRadius: 0,seed: 0))
        try canvas.draw([(clip,1)]); let edge = canvas.pixel(240,0)
        clip.effects?.blur = .init(radius: 40)
        try canvas.draw([(clip,1)]); XCTAssertGreaterThan(canvas.pixel(240,0)[0], edge[0])
    }

    @MainActor func testEditorPositionHistoryAndCopy() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(start: 0,end: 4)
        var commits = 0
        editor.onCommit = { clip.effects = $0; commits += 1; editor.load(clip,editable: true) }
        editor.load(clip,editable: true)
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let menu = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" }?.menu)
        let item = try XCTUnwrap(menu.effectItem(titled: "電撃ビーム"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action),to: item.target,from: item))
        XCTAssertEqual(commits,1)
        for field in Beam.fields {
            let control = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value."+field.parameter.rawValue })
            XCTAssertEqual(control.doubleValue,field.parameter.defaultValue)
            XCTAssertNotNil(control.onCreateAutomation); XCTAssertNotNil(control.onEditMusic)
        }
        let width = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value.beamWidth" })
        XCTAssertTrue(width.onDragStart?() == true); width.onDragChange?(0.5)
        XCTAssertEqual(commits,1); width.onDragEnd?(); XCTAssertEqual(commits,2)
        XCTAssertEqual(clip.effects?.electricBeam?.width,3.5)
        XCTAssertTrue(width.onDragStart?() == true); width.onDragChange?(2); XCTAssertTrue(width.cancelNumberDrag())
        XCTAssertEqual(clip.effects?.electricBeam?.width,3.5)
        width.onReset?(); XCTAssertEqual(clip.effects?.electricBeam?.width,3)
        let shuffle = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "visuals.effects.beamShuffle" })
        let seed = clip.effects?.electricBeam?.seed
        XCTAssertTrue(shuffle.sendAction(shuffle.action,to: shuffle.target)); XCTAssertNotEqual(seed,clip.effects?.electricBeam?.seed)
        let color = try XCTUnwrap(views.compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.beamColor" })
        color.activate(true); NSColorPanel.shared.color = .red
        RunLoop.main.run(until: Date().addingTimeInterval(0.02)); color.deactivate()
        XCTAssertEqual(clip.effects?.electricBeam?.color,RGBColor(.red))
        let visuals = VisualEditor(); _ = visuals.view
        visuals.duration = 10; visuals.currentTime = 1; visuals.setAvailable(true)
        _ = clip.setKey(.beamX,at: 0,value: 960)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        visuals.commit(track,selectedID: clip.id)
        let history = EditHistory(); history.reset(EditSnapshot(visuals: track))
        visuals.onChange = { history.record(EditSnapshot(visuals: $0)) }
        let target = try XCTUnwrap(visuals.previewHandleTarget(for: .beamY))
        let transaction = try XCTUnwrap(target.begin()); transaction.update(CGPoint(x: 1000,y: 650)); transaction.finish(true)
        XCTAssertEqual(visuals.track.clip(clip.id)?.curve(.beamX)?.keys.first?.value,1000)
        XCTAssertEqual(history.undo()?.visuals,track)
        let beforeCancel = visuals.track
        let cancel = try XCTUnwrap(target.begin()); cancel.update(.zero); cancel.finish(false)
        XCTAssertEqual(visuals.track,beforeCancel)
        let placement = PlacementEditor(); _ = placement.view
        placement.duration = 10; placement.restoreTab(.visuals); placement.setAvailable(hasAudio: true,isBusy: false)
        placement.visuals.load(track,projectURL: URL(fileURLWithPath: "/tmp/beam.mvproject"))
        placement.timeline.onImageSelect?(clip.id,track.layers[0].id)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        placement.editClip(.copy,pasteboard: board); placement.editClip(.duplicate,pasteboard: board)
        let duplicate = try XCTUnwrap(placement.visuals.track.clips.last)
        XCTAssertEqual(duplicate.effects?.electricBeam,clip.effects?.electricBeam)
        XCTAssertNotEqual(duplicate.effects?.nodes.first?.id,clip.effects?.nodes.first?.id)
        XCTAssertNotEqual(duplicate.curve(.beamX)?.keys.first?.id,clip.curve(.beamX)?.keys.first?.id)
        clip.audioModulations[.beamBrightness] = AudioModulation(source: .beat, amount: 30)
        editor.load(clip, editable: true)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.electricBeam); XCTAssertNil(clip.curve(.beamX))
        XCTAssertNil(clip.audioModulations[.beamBrightness])
    }

    func testLinearHDRCoverageAndFiniteGlowAgainstReference() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try ElectricBeamRenderer(device: device, library: SceneShaders.library(device: device))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1920, height: 1080, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let beam = Beam(x: 960, y: 400, angle: 0, length: 1200, spread: 0, count: 1,
                        width: 16, bend: 0, glowRadius: 40, brightness: 400, seed: 0)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 0.4)
        try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        try renderer.render(into: target, effect: beam, localTime: 0, scale: 1, padding: 0, commands: commands)
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
        let segment = try XCTUnwrap(ElectricBeamGeometry.paths(.init(beam, at: 0)).first?.first)
        let halfWidth = Double(segment.widths.x)
        let base = [0.1, 0.2, 0.3]
        let srgb = [beam.color.red, beam.color.green, beam.color.blue]
        let linear = srgb.map { $0 <= 0.04045 ? $0/12.92 : pow(($0+0.055)/1.055, 2.4) }
        for screenY in [400, 410, 430, 450, 500] {
            var pixel = [Float16](repeating: 0, count: 4)
            target.getBytes(&pixel, bytesPerRow: 8, from: MTLRegionMake2D(960,1079-screenY,1,1), mipmapLevel: 0)
            let distance = abs(Double(screenY)+0.5-400)
            let core = min(1, max(0, halfWidth+0.5-distance))
            let u = min(1, max(0, (distance-halfWidth)/40))
            let glow = pow(1-u*u*(3-2*u),3)*0.35
            for c in 0..<3 {
                let expected = base[c] + ((linear[c]*0.25+0.75)*core + linear[c]*glow)*4
                XCTAssertEqual(Double(pixel[c]), expected, accuracy: 0.006)
                XCTAssertTrue(pixel[c].isFinite)
            }
            XCTAssertEqual(Double(pixel[3]),0.4,accuracy: 0.001, "発光でcoverageを増やさない")
            if screenY == 400 { XCTAssertGreaterThan(Float(pixel[0]), 1, "HDRを保持する") }
        }
    }

    func testExtremeValuesAnd1080pCost() throws {
        let canvas = try EffectTestCanvas()
        for count in [1,3,10] {
            let effect = Beam(length: 7680,spread: 1080,width: 40,bend: 400,glowRadius: 300,brightness: 400,seed: 8)
            let clips = (0..<count).map { (VisualClip(start: 0,end: 3,effects: ImageEffects(electricBeam: effect)),$0) }
            var maximum = 0.0
            for frame in 0..<3 {
                try canvas.draw(clips,time: Double(frame)/30); maximum = max(maximum,canvas.lastGPUMS)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            print("Electric beam 1080p maximum settings \(count) layers GPU max \(maximum)ms, process peak RSS \(usage.ru_maxrss) bytes")
            XCTAssertGreaterThan(maximum,0)
        }
        for beam in [Beam(length: 1,count: 1,width: 0.5,glowRadius: 0,seed: 0),
                     Beam(x: -1920,y: -1080,angle: 90,length: 7680,bend: 400,seed: 0)] {
            XCTAssertTrue(beam.isValid)
            try canvas.draw([(VisualClip(start: 0,end: 3,effects: ImageEffects(electricBeam: beam)),1)])
        }
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
        let clip = VisualClip(start: 0, end: 0.3, effects: ImageEffects(electricBeam: .init(seed: 4)))
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let features = try AudioAnalyzer.analyze(url: audio)
        let output = directory.appendingPathComponent("beam.mp4")
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
            for (x, y) in [(960, 540), (600, 700), (1400, 300), (100, 100), (1800, 900)] {
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

}
