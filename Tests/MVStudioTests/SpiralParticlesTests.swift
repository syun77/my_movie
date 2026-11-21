import AppKit
import AVFoundation
import Darwin
import Metal
import XCTest
@testable import MVStudio

final class SpiralParticlesTests: XCTestCase {
    typealias Spiral = ImageEffects.SpiralParticles

    func testConvergenceDirectionLifetimeAndBoundary() {
        var s = Spiral(seed: 17)
        for i in 0..<200 {
            XCTAssertTrue((2.55...3.45).contains(s.lifetime(index: i)))
            XCTAssertTrue((0..<1).contains(s.phase(index: i)))
            var previous = Double.infinity
            for step in 0...100 {
                let p = s.instance(index: i, progress: Double(step)/100)
                let radius = hypot(Double(p.x)-s.x, Double(p.y)-s.y)
                XCTAssertLessThanOrEqual(radius, previous + 0.001); previous = radius
            }
            XCTAssertEqual(s.instance(index: i, progress: 0).w, 0)
            XCTAssertEqual(s.instance(index: i, progress: 1), SIMD4(Float(s.x), Float(s.y), 0, 0))
        }
        s.turns = 0
        let p = s.instance(index: 4, progress: 0.2), q = s.instance(index: 4, progress: 0.8)
        XCTAssertEqual(atan2(p.y-Float(s.y),p.x-Float(s.x)),atan2(q.y-Float(s.y),q.x-Float(s.x)),accuracy: 0.001)
        s.turns = 0.25
        func angle(_ value: Spiral, _ u: Double) -> Double {
            let p = value.instance(index: 0, progress: u); return atan2(Double(p.y)-value.y,Double(p.x)-value.x)
        }
        func delta(_ value: Spiral) -> Double {
            let a = angle(value,0.4)-angle(value,0.2); return atan2(sin(a),cos(a))
        }
        XCTAssertGreaterThan(delta(s),0)
        s.direction = .counterclockwise; XCTAssertLessThan(delta(s),0)
        s.radius = 0
        XCTAssertTrue(s.instances(at: -3).allSatisfy { $0.x == Float(s.x) && $0.y == Float(s.y) })
    }

    func testIdentitySeekStaticClockAndValidation() {
        var s = Spiral(seed: 17)
        let at = s.instances(at: 2.5)
        _ = s.instances(at: 9); _ = s.instances(at: -4)
        XCTAssertEqual(s.instances(at: 2.5),at)
        s.count = 1000; XCTAssertEqual(Array(s.instances(at: 2.5).prefix(200)),at)
        s.speed = 0; XCTAssertEqual(s.instances(at: -4),s.instances(at: 40))
        for field in Spiral.fields {
            for bad in [Double.nan, .infinity, field.range.lowerBound-1, field.range.upperBound+1] {
                var v = Spiral(seed: 0); v[keyPath: field.path] = bad
                XCTAssertFalse(ImageEffects(spiralParticles: v).isValid)
            }
        }
        s.phaseOffset = .infinity; XCTAssertFalse(s.isValid)
        s.phaseOffset = 0; s.color.red = .nan; XCTAssertFalse(s.isValid)
    }

    func testAutomationTrimLFOAndImageAppearance() throws {
        var clip = VisualClip(start: 1,end: 8,effects: ImageEffects(spiralParticles: Spiral(seed: 17)))
        for field in Spiral.fields {
            XCTAssertEqual(field.parameter.effectKind,.spiralParticles)
            XCTAssertEqual(field.parameter.defaultValue,Spiral(seed: 0)[keyPath: field.path])
            _ = clip.setKey(field.parameter,at: 0,value: field.range.lowerBound)
            _ = clip.setKey(field.parameter,at: 4,value: field.range.upperBound)
            var expected = (field.range.lowerBound+field.range.upperBound)/2
            if field.parameter == .spiralCount { expected = expected.rounded() }
            XCTAssertEqual(try XCTUnwrap(clip.evaluatedEffects(at: 2)?.spiralParticles)[keyPath: field.path],expected,accuracy: 1e-8)
        }
        clip.audioModulations[.spiralRadius] = AudioModulation(source: .beat,amount: 100)
        let settings = SceneSettings(bpm: 120)
        let value = try XCTUnwrap(clip.evaluatedEffects(at: 3,settings: settings)?.spiralParticles)
        clip.trimStart(to: 2)
        let trimmed = try XCTUnwrap(clip.evaluatedEffects(at: 3,settings: settings)?.spiralParticles)
        XCTAssertEqual(value.instances(at: 2),trimmed.instances(at: 1))
        clip.effects?.setAppearance(ParticleAppearance(),for: .spiralParticles)
        let node = try XCTUnwrap(clip.effects?.nodes.first)
        let records = node.imageParticleInstances(at: 1,aspect: SIMD2(1,0.5))
        XCTAssertEqual(records.first?.count,200)
        XCTAssertTrue(records[0].allSatisfy { $0.geometry.z.isFinite && $0.motion.y.isFinite })
        var lfo = LFOSettings(); lfo.amount = 40; lfo.timebase = .hertz
        clip.setAutomation(.init(parameter: .spiralX, mode: .lfo, lfo: lfo))
        XCTAssertNotEqual(clip.evaluatedEffects(at: 2)?.spiralParticles?.x,clip.evaluatedEffects(at: 2.5)?.spiralParticles?.x)
        clip.effects?.spiralParticles = nil
        XCTAssertNil(clip.curve(.spiralX)); XCTAssertNil(clip.audioModulations[.spiralRadius])
    }

    func testPersistenceAndVersionBoundary() throws {
        var track = VisualTrack()
        let clip = VisualClip(start: 0,end: 4,effects: ImageEffects(spiralParticles: Spiral(seed: 17)))
        track.layers[0].clips = [clip]
        let url = URL(fileURLWithPath: "/tmp/spiral.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/tone.wav"),visuals: track,settings: SceneSettings(),projectURL: url)
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try ProjectMigrator.read(data,at: url).project.visuals,track)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for v in 16...18 {
            root["version"] = v
            XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root),at: url))
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v18",withExtension: "json",subdirectory: "Fixtures/Projects"))
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var heights = root["timelineHeights"] as? [String: Any] ?? [:]
        heights["nodeAutomation"] = [UUID().uuidString+"/spiralRadius": 62]; root["timelineHeights"] = heights
        XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root),at: url))
    }

    @MainActor func testInspectorEditingAndHandle() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(start: 0,end: 4)
        var commits = 0, preview: ImageEffects?
        editor.onCommit = { clip.effects = $0; commits += 1; editor.load(clip,editable: true) }
        editor.onPreview = { preview = $0 }
        editor.load(clip,editable: true)
        func all(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(all) }
        func find<T: NSView>(_ id: String, _ type: T.Type) throws -> T { try XCTUnwrap(all(editor).first { $0.identifier?.rawValue == id } as? T) }
        let add = try find("visuals.effects.add",NSPopUpButton.self)
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "渦巻き粒子"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action),to: item.target,from: item))
        XCTAssertEqual(commits,1)
        let turns = try find("visuals.value.spiralTurns",DragValueField.self)
        XCTAssertEqual(turns.doubleValue,1.5)
        XCTAssertTrue(turns.onDragStart?() == true); turns.onDragChange?(3)
        XCTAssertEqual(commits,1); XCTAssertNotNil(preview)
        XCTAssertTrue(turns.cancelNumberDrag()); XCTAssertNil(preview)
        XCTAssertEqual(clip.effects?.spiralParticles?.turns,1.5)
        XCTAssertTrue(turns.onDragStart?() == true); turns.onDragChange?(3); turns.onDragEnd?()
        XCTAssertEqual(commits,2); XCTAssertEqual(clip.effects?.spiralParticles?.turns,1.8)
        turns.onReset?(); XCTAssertEqual(clip.effects?.spiralParticles?.turns,1.5)
        turns.stringValue = "2.5"; editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,object: turns))
        XCTAssertEqual(clip.effects?.spiralParticles?.turns,2.5)
        let direction = try find("visuals.effects.spiralDirection",NSPopUpButton.self)
        direction.selectItem(at: 1); XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(direction.action),to: direction.target,from: direction))
        XCTAssertEqual(clip.effects?.spiralParticles?.direction,.counterclockwise)
        let pair = try XCTUnwrap(PreviewPositionPair.containing(.spiralX))
        let moved = pair.moving(clip,to: CGPoint(x: 500,y: 300))
        XCTAssertEqual(moved.baseValue(.spiralX),500); XCTAssertEqual(moved.baseValue(.spiralY),300)
    }

    func testRenderingPositionColorOpacitySeekAndPadding() throws {
        let canvas = try EffectTestCanvas(scale: 0.5)
        var s = Spiral(x: 480,y: 280,radius: 0,count: 1,diameter: 100,color: RGBColor(.red),seed: 17)
        var clip = VisualClip(start: 0,end: 4,effects: ImageEffects(spiralParticles: s))
        try canvas.draw([])
        let empty = canvas.pixel(240,140), emptyLower = canvas.pixel(240,400)
        try canvas.draw([(clip,0)])
        let point = canvas.pixel(240,140)
        XCTAssertGreaterThan(point[2],40); XCTAssertEqual(canvas.pixel(240,400),emptyLower)
        clip.effects?.blur = .init(radius: 10)
        try canvas.draw([(clip,0)])
        XCTAssertGreaterThan(canvas.pixel(240,140)[2],10)
        clip.effects?.blur = nil
        clip.fixedValues[.opacity] = 0; try canvas.draw([(clip,0)]); XCTAssertEqual(canvas.pixel(240,140),empty)
        clip.fixedValues[.opacity] = nil
        s.radius = 800; s.count = 200; s.diameter = 16; s.x = 960; s.y = 540
        clip.effects = ImageEffects(spiralParticles: s)
        try canvas.draw([(clip,0)],time: 0.5); try canvas.save("/tmp/my-movie-spiral-preview.png")
        let instances = s.instances(at: 0.5)
        let points = instances.filter { $0.x > 1 && $0.x < 1919 && $0.y > 1 && $0.y < 1079 && $0.w > 0.2 }.prefix(30).map { (Int($0.x/2),Int($0.y/2)) }
        let before = points.map { canvas.pixel($0.0,$0.1) }
        try canvas.draw([(clip,0)],time: 2); try canvas.draw([(clip,0)],time: 0.5)
        XCTAssertEqual(points.map { canvas.pixel($0.0,$0.1) },before)
        XCTAssertTrue(before.contains { $0[2] > 20 })
        // A particle just outside the viewport contributes through a following blur.
        s.x = -15; s.y = 540; s.radius = 0; s.count = 1; s.diameter = 100
        clip.effects = ImageEffects(blur: .init(radius: 20), spiralParticles: s)
        try canvas.draw([(clip,0)]); XCTAssertGreaterThan(canvas.pixel(0,270)[2],2)
    }

    func testImageOrientationRotationMissingAndDownstreamMask() throws {
        let canvas = try EffectTestCanvas(scale: 0.5)
        let context = try XCTUnwrap(CGContext(data: nil,width: 80,height: 40,bitsPerComponent: 8,bytesPerRow: 0,
            space: MetalSceneRenderer.sRGB,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1)); context.fill(CGRect(x: 0,y: 20,width: 80,height: 20))
        context.setFillColor(CGColor(red: 0,green: 1,blue: 0,alpha: 0.5)); context.fill(CGRect(x: 0,y: 0,width: 80,height: 20))
        let id = UUID(), frame = VisualFrame(try XCTUnwrap(context.makeImage()))
        var clip = VisualClip(start: 0,end: 4,effects: ImageEffects(spiralParticles: Spiral(x: 480,y: 280,radius: 0,count: 1,seed: 17)))
        var appearance = ParticleAppearance(); appearance.mode = .image; appearance.assetID = id; appearance.size = 400
        clip.effects?.setAppearance(appearance,for: .spiralParticles)
        try canvas.draw([(clip,0)],particleImages: [id: frame])
        let upper = canvas.pixel(240,125), lower = canvas.pixel(240,155)
        XCTAssertGreaterThan(upper[2],upper[1]); XCTAssertGreaterThan(lower[1],lower[2])
        appearance.angle = 90; clip.effects?.setAppearance(appearance,for: .spiralParticles)
        try canvas.draw([(clip,0)],particleImages: [id: frame])
        XCTAssertGreaterThan(canvas.pixel(255,140)[2],canvas.pixel(255,140)[1])
        XCTAssertGreaterThan(canvas.pixel(225,140)[1],canvas.pixel(225,140)[2])
        clip.effects?.blur = .init(radius: 10)
        try canvas.draw([(clip,0)],particleImages: [id: frame])
        XCTAssertGreaterThan(canvas.pixel(255,140)[2],20)
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(clip,0)],particleImages: [id: frame])
        let masked = canvas.pixel(255,140)
        try canvas.draw([]); XCTAssertEqual(masked,canvas.pixel(255,140))
        clip.effects?.mask = nil; clip.effects?.blur = nil
        try canvas.draw([(clip,0)]); XCTAssertEqual(canvas.pixel(255,140),masked)
        clip.effects?.spiralParticles = .init(seed: 17)
        appearance.mode = .standard; clip.effects?.setAppearance(appearance,for: .spiralParticles)
        try canvas.draw([(clip,0)]); try canvas.save("/tmp/my-movie-spiral-default.png")
    }

    func test1080pParticleAndLayerBudget() throws {
        let canvas = try EffectTestCanvas()
        for particles in [200.0,1000.0] {
            for layers in [1,3,10] {
                var maximum = 0.0
                for frame in 0..<3 {
                    let clips = (0..<layers).map { i in
                        (VisualClip(start: 0,end: 3,effects: ImageEffects(spiralParticles: Spiral(count: particles,seed: UInt32(i)))),i)
                    }
                    try canvas.draw(clips,time: Double(frame)/30); maximum = max(maximum,canvas.lastGPUMS)
                }
                var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
                print("Spiral 1080p \(Int(particles)) particles \(layers) layers GPU max \(maximum)ms, process peak RSS \(usage.ru_maxrss) bytes")
                XCTAssertGreaterThan(maximum,0)
            }
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
        var clip = VisualClip(start: 0, end: 0.3, effects: ImageEffects(spiralParticles: Spiral(radius: 700,diameter: 80,seed: 17)))
        _ = clip.setKey(.spiralTurns,at: 0,value: 0.5)
        _ = clip.setKey(.spiralTurns,at: 0.3,value: 2)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let features = try AudioAnalyzer.analyze(url: audio)
        let output = directory.appendingPathComponent("spiral.mp4")
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
            let v = try XCTUnwrap(clip.evaluatedEffects(at: time)?.spiralParticles)
            let probes = v.instances(at: time).filter { $0.x > 50 && $0.x < 1870 && $0.y > 50 && $0.y < 1030 && $0.w > 0.3 }.prefix(12)
            for p in probes {
                let x = Int(p.x), y = Int(p.y)
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
