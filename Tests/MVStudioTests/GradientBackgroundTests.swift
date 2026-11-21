import AppKit
import AVFoundation
import Darwin
import Metal
import XCTest
@testable import MVStudio

final class GradientBackgroundTests: XCTestCase {
    typealias Gradient = ImageEffects.GradientBackground

    func testSpatialProfileAndValidation() throws {
        var g = Gradient(width: 100)
        XCTAssertEqual(g.mixture(at: CGPoint(x: 910, y: 540)), 0)
        XCTAssertEqual(g.mixture(at: CGPoint(x: 960, y: 540)), 0.5)
        XCTAssertEqual(g.mixture(at: CGPoint(x: 1010, y: 540)), 1)
        g.bias = 100
        XCTAssertEqual(g.mixture(atFraction: 0.5), pow(0.5, 16))
        g.bias = -100
        XCTAssertEqual(g.mixture(atFraction: 0.5), pow(0.5, 1/16))
        g.pattern = .mirrored
        for bias in [-100.0, 0, 100] {
            g.bias = bias
            XCTAssertEqual(g.mixture(atFraction: 0), 0)
            XCTAssertEqual(g.mixture(atFraction: 0.5), 1)
            XCTAssertEqual(g.mixture(atFraction: 1), 0)
            XCTAssertEqual(g.mixture(atFraction: 0.25), g.mixture(atFraction: 0.75))
        }
        g.shape = .radial; g.position = 100; g.bias = 0
        XCTAssertEqual(g.mixture(at: CGPoint(x: 960, y: 540)), 0)
        XCTAssertEqual(g.mixture(at: CGPoint(x: 1060, y: 540)), 1)
        XCTAssertEqual(g.mixture(at: CGPoint(x: 960, y: 640)), 1)
        for field in Gradient.fields {
            for number in [Double.nan, .infinity, field.range.lowerBound-1, field.range.upperBound+1] {
                var bad = Gradient(); bad[keyPath: field.path] = number
                XCTAssertFalse(ImageEffects(gradientBackground: bad).isValid)
            }
        }
        g.colorB.green = .nan; XCTAssertFalse(g.isValid)
    }

    func testAutomationTrimPersistenceAndSchemaBoundary() throws {
        var clip = VisualClip(start: 1, end: 5, effects: ImageEffects(gradientBackground: .init()))
        for field in Gradient.fields {
            XCTAssertEqual(field.parameter.effectKind, .gradientBackground)
            XCTAssertEqual(field.parameter.defaultValue, Gradient()[keyPath: field.path])
            _ = clip.setKey(field.parameter, at: 1, value: field.range.lowerBound)
            _ = clip.setKey(field.parameter, at: 3, value: field.range.upperBound)
            XCTAssertEqual(try XCTUnwrap(clip.evaluatedEffects(at: 2)?.gradientBackground)[keyPath: field.path],
                           (field.range.lowerBound + field.range.upperBound)/2, accuracy: 1e-8)
        }
        clip.audioModulations[.gradientPosition] = AudioModulation(source: .beat, amount: 100)
        let settings = SceneSettings(bpm: 120)
        let atTwo = clip.evaluatedEffects(at: 2, settings: settings)?.gradientBackground
        clip.trimStart(to: 1.5)
        XCTAssertEqual(clip.evaluatedEffects(at: 2, settings: settings)?.gradientBackground, atTwo)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let url = URL(fileURLWithPath: "/tmp/gradient.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/tone.wav"), visuals: track, settings: settings, projectURL: url)
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try ProjectMigrator.read(data, at: url).project.visuals, track)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for version in 14...16 {
            root["version"] = version
            XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject: root), at: url))
        }
        clip.effects?.gradientBackground = nil
        XCTAssertNil(clip.curve(.gradientPosition)); XCTAssertNil(clip.audioModulations[.gradientPosition])
    }

    func testMetalReferenceCoveragePaddingAndOrientation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try GradientBackgroundRenderer(device: device, library: SceneShaders.library(device: device))
        let scale = 0.25, padding = 8.0
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 496, height: 286, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var base = [0.12, 0.24, 0.48, 0.25]
        func draw(_ g: Gradient) throws {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(base[0], base[1], base[2], base[3])
            try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
            try renderer.render(into: target, effect: g, scale: scale, padding: padding, commands: commands)
            commands.commit(); commands.waitUntilCompleted(); XCTAssertEqual(commands.status, .completed)
        }
        func pixel(_ x: Int, _ y: Int) -> [Double] {
            var result = [Float16](repeating: 0, count: 4)
            target.getBytes(&result, bytesPerRow: 8, from: MTLRegionMake2D(x,y,1,1), mipmapLevel: 0)
            return result.map(Double.init)
        }
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
        for shape in Gradient.Shape.allCases {
            for pattern in Gradient.Pattern.allCases {
                for bias in [-100.0,0,100] {
                    for angle in [0.0,90,180,270,33] {
                        let g = Gradient(colorA: .init(red: 0.1,green: 0.2,blue: 0.3), colorB: .init(red: 0.8,green: 0.6,blue: 0.4),
                                         shape: shape, pattern: pattern, x: 760, y: 340, position: 250, width: 800, angle: angle, bias: bias, opacity: 50)
                        try draw(g)
                        for (x,y) in [(100,70),(220,120),(360,200)] {
                            let p = CGPoint(x: (Double(x)+0.5-padding)/scale, y: (Double(target.height)-Double(y)-0.5-padding)/scale)
                            let offsets = [-0.25/scale,0.25/scale]
                            let t = offsets.flatMap { dx in offsets.map { dy in g.mixture(at: CGPoint(x: p.x+dx,y: p.y+dy)) } }.reduce(0,+)/4
                            let a = [g.colorA.red,g.colorA.green,g.colorA.blue].map(linear)
                            let b = [g.colorB.red,g.colorB.green,g.colorB.blue].map(linear)
                            for c in 0..<3 {
                                XCTAssertEqual(pixel(x,y)[c], base[c] + (a[c]*(1-t)+b[c]*t)*0.5*(1-base[3]), accuracy: 0.0015)
                            }
                            XCTAssertEqual(pixel(x,y)[3],0.625,accuracy: 0.001)
                        }
                        for c in 0..<4 { XCTAssertEqual(pixel(0,0)[c],base[c],accuracy: 0.001) }
                    }
                }
            }
        }
        try draw(Gradient(opacity: 0))
        for c in 0..<4 { XCTAssertEqual(pixel(220,120)[c],base[c],accuracy: 0.001) }
        for alpha in [0.0,1.0] {
            base[3] = alpha
            try draw(Gradient(colorA: RGBColor(.white),colorB: RGBColor(.white),opacity: 50))
            for c in 0..<3 { XCTAssertEqual(pixel(220,120)[c],base[c]+0.5*(1-alpha),accuracy: 0.0015) }
            XCTAssertEqual(pixel(220,120)[3],alpha+0.5*(1-alpha),accuracy: 0.001)
        }
    }

    func testChainOrderOpacityMasksAndSeek() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(gradientBackground: .init(colorA: RGBColor(.red),colorB: RGBColor(.blue),angle: 90))
        try canvas.draw([(clip,0)]); let top = canvas.pixel(240,10), bottom = canvas.pixel(240,260)
        XCTAssertGreaterThan(top[2],bottom[2]); XCTAssertGreaterThan(bottom[0],top[0])
        try canvas.save("/tmp/my-movie-gradient-preview.png")
        let pure = canvas.pixel(240,135)
        clip.effects?.solidBackground = .init(color: RGBColor(.green))
        try canvas.draw([(clip,0)]); XCTAssertEqual(canvas.pixel(240,135),pure)
        let solid = try XCTUnwrap(clip.effects?.nodes.last?.id); clip.effects?.move(solid,to: 0)
        try canvas.draw([(clip,0)]); XCTAssertEqual(canvas.pixel(240,135),[0,255,0,255])
        clip.effects?.solidBackground = nil
        clip.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try canvas.draw([(clip,0)]); let masked = canvas.pixel(240,135)
        clip.effects?.mask = nil
        clip.effects?.gradientBackground?.opacity = 0
        try canvas.draw([(clip,0)]); XCTAssertEqual(canvas.pixel(240,135),masked)
        clip.effects?.gradientBackground?.opacity = 100
        clip.fixedValues[.opacity] = 50
        try canvas.draw([(clip,0)]); XCTAssertLessThan(canvas.pixel(240,135)[2],pure[2])
        clip.fixedValues[.opacity] = 100
        _ = clip.setKey(.gradientAngle,at: 0,value: 0); _ = clip.setKey(.gradientAngle,at: 2,value: 180)
        try canvas.draw([(clip,0)],time: 0.5); let a = canvas.pixel(50,10)
        try canvas.draw([(clip,0)],time: 1.5); XCTAssertNotEqual(canvas.pixel(50,10),a)
        try canvas.draw([(clip,0)],time: 0.5); XCTAssertEqual(canvas.pixel(50,10),a)
        clip.effects = ImageEffects(gradientBackground: Gradient(colorA: RGBColor(.black),colorB: RGBColor(.cyan),
                                                                shape: .radial,pattern: .mirrored,position: 340,width: 360,bias: 20))
        try canvas.draw([(clip,0)])
        try canvas.save("/tmp/my-movie-gradient-ring.png")
        clip.effects?.gradientBackground?.shape = .linear
        clip.effects?.gradientBackground?.position = 0
        clip.effects?.gradientBackground?.angle = 35
        try canvas.draw([(clip,0)])
        try canvas.save("/tmp/my-movie-gradient-band.png")
    }

    @MainActor func testEditorSessionsNumericCancelAndModes() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(start: 0,end: 4)
        var commits = 0, preview: ImageEffects?
        let history = EditHistory(); history.reset(EditSnapshot())
        var group: UUID?
        editor.onColorSession = { group = $0 }
        editor.onCommit = { clip.effects = $0; commits += 1; history.record(EditSnapshot(visuals: VisualTrack(layers: [VisualLayer(name: "背景", clips: [clip])])),group: group); editor.load(clip,editable: true) }
        editor.onPreview = { preview = $0 }
        editor.load(clip,editable: true)
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        func find<T: NSView>(_ id: String, _ type: T.Type) throws -> T { try XCTUnwrap(views.first { $0.identifier?.rawValue == id } as? T) }
        let menu = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" }?.menu)
        let item = try XCTUnwrap(menu.effectItem(titled: "グラデーション背景"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action),to: item.target,from: item))
        XCTAssertEqual(commits,1)
        let width = try find("visuals.value.gradientWidth",DragValueField.self)
        XCTAssertEqual(width.doubleValue,192)
        XCTAssertTrue(width.onDragStart?() == true); width.onDragChange?(100)
        XCTAssertEqual(commits,1); XCTAssertEqual(preview?.gradientBackground?.width,2920)
        XCTAssertTrue(width.cancelNumberDrag()); XCTAssertNil(preview); XCTAssertEqual(commits,1)
        XCTAssertTrue(width.onDragStart?() == true); width.onDragChange?(100); width.onDragEnd?()
        XCTAssertEqual(commits,2); XCTAssertEqual(clip.effects?.gradientBackground?.width,2920); width.onReset?(); XCTAssertEqual(clip.effects?.gradientBackground?.width,1920)
        width.stringValue = "0"; editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,object: width))
        XCTAssertEqual(clip.effects?.gradientBackground?.width,1920)
        width.stringValue = "120"; editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,object: width))
        XCTAssertEqual(clip.effects?.gradientBackground?.width,1200)
        XCTAssertEqual(width.doubleValue,120)
        width.onReset?(); XCTAssertEqual(width.doubleValue,192)
        for field in Gradient.fields {
            let control = try find("visuals.value."+field.parameter.rawValue,DragValueField.self)
            XCTAssertNotNil(control.onCreateAutomation); XCTAssertNotNil(control.onEditMusic)
        }
        let shape = try find("visuals.effects.gradient.shape",NSPopUpButton.self)
        shape.selectItem(at: 1); XCTAssertTrue(shape.sendAction(shape.action,to: shape.target))
        XCTAssertFalse(try find("visuals.value.gradientAngle",DragValueField.self).isEnabled)
        let outward = try find("visuals.effects.gradient.outward",NSButton.self)
        XCTAssertTrue(outward.sendAction(outward.action,to: outward.target)); XCTAssertEqual(clip.effects?.gradientBackground?.position,960)
        let well = try find("visuals.effects.gradient.colorA",SessionColorWell.self)
        let beforeColor = history.current
        well.activate(true)
        XCTAssertNotNil(well.sessionID)
        for color in [NSColor.red,.green,.blue] {
            well.color = color; XCTAssertTrue(well.sendAction(well.action,to: well.target))
        }
        well.deactivate(); XCTAssertNil(well.sessionID)
        XCTAssertEqual(history.undo(),beforeColor)
        XCTAssertEqual(history.redo()?.visuals.clips.first?.effects?.gradientBackground?.colorA,RGBColor(.blue))
        let swap = try find("visuals.effects.gradient.swap",NSButton.self)
        XCTAssertTrue(swap.sendAction(swap.action,to: swap.target)); XCTAssertEqual(clip.effects?.gradientBackground?.colorB,RGBColor(.blue))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 280,pixelsHigh: 112,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        let profile = try XCTUnwrap(views.compactMap { $0 as? GradientProfileView }.first)
        profile.frame.size = NSSize(width: 280,height: 112); profile.cacheDisplay(in: profile.bounds,to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png,properties: [:])).write(to: URL(fileURLWithPath: "/tmp/my-movie-gradient-profile.png"))
    }
    @MainActor func testPositionBaseMovementCopyAndDelete() throws {
        _ = NSApplication.shared
        let visuals = VisualEditor(); _ = visuals.view
        visuals.duration = 10; visuals.currentTime = 1; visuals.setAvailable(true)
        var clip = VisualClip(start: 0,end: 4,effects: ImageEffects(gradientBackground: .init()))
        _ = clip.setKey(.gradientX,at: 0,value: 960)
        clip.audioModulations[.gradientWidth] = AudioModulation(source: .beat,amount: 100)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        visuals.commit(track,selectedID: clip.id)
        let history = EditHistory(); history.reset(EditSnapshot(visuals: track))
        visuals.onChange = { history.record(EditSnapshot(visuals: $0)) }
        let target = try XCTUnwrap(visuals.previewHandleTarget(for: .gradientY))
        let move = try XCTUnwrap(target.begin()); move.update(CGPoint(x: 1000,y: 650)); move.finish(true)
        XCTAssertEqual(visuals.track.clip(clip.id)?.curve(.gradientX)?.keys.first?.value,1000)
        XCTAssertEqual(history.undo()?.visuals,track)
        let before = visuals.track
        let cancel = try XCTUnwrap(target.begin()); cancel.update(.zero); cancel.finish(false)
        XCTAssertEqual(visuals.track,before)
        let placement = PlacementEditor(); _ = placement.view
        placement.duration = 10; placement.restoreTab(.visuals); placement.setAvailable(hasAudio: true,isBusy: false)
        placement.visuals.load(track,projectURL: URL(fileURLWithPath: "/tmp/gradient.mvproject"))
        placement.timeline.onImageSelect?(clip.id,track.layers[0].id)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        placement.editClip(.copy,pasteboard: board); placement.editClip(.duplicate,pasteboard: board)
        let duplicate = try XCTUnwrap(placement.visuals.track.clips.last)
        XCTAssertEqual(duplicate.start,4)
        XCTAssertEqual(duplicate.effects?.gradientBackground,clip.effects?.gradientBackground)
        XCTAssertEqual(duplicate.audioModulations[.gradientWidth],clip.audioModulations[.gradientWidth])
        XCTAssertNotEqual(duplicate.effects?.nodes.first?.id,clip.effects?.nodes.first?.id)
        XCTAssertNotEqual(duplicate.curve(.gradientX)?.keys.first?.id,clip.curve(.gradientX)?.keys.first?.id)
        clip.effects?.gradientBackground = nil
        XCTAssertNil(clip.curve(.gradientX)); XCTAssertNil(clip.audioModulations[.gradientWidth])
    }

    func testExtremeValuesAnd1080pCost() throws {
        let canvas = try EffectTestCanvas()
        for count in [1,3,10] {
            var maximum = 0.0
            for frame in 0..<3 {
                let clips = (0..<count).map { i in
                    (VisualClip(start: 0,end: 3,effects: ImageEffects(gradientBackground: Gradient(
                        shape: .radial,pattern: .mirrored,position: 400+Double(frame)*20,width: 600,bias: 100))),i)
                }
                try canvas.draw(clips,time: Double(frame)/30); maximum = max(maximum,canvas.lastGPUMS)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            print("Gradient 1080p \(count) layers GPU max \(maximum)ms, process peak RSS \(usage.ru_maxrss) bytes")
            XCTAssertGreaterThan(maximum,0)
        }
        for gradient in [Gradient(x: -7680,y: 7680,position: -7680,width: 1,angle: 3600,bias: -100),
                         Gradient(shape: .radial,pattern: .mirrored,x: 7680,y: -7680,position: 7680,width: 15360,bias: 100)] {
            XCTAssertTrue(gradient.isValid)
            try canvas.draw([(VisualClip(start: 0,end: 3,effects: ImageEffects(gradientBackground: gradient)),0)])
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
        var clip = VisualClip(start: 0, end: 0.3, effects: ImageEffects(gradientBackground: .init(
            colorA: RGBColor(.red), colorB: RGBColor(.blue), shape: .radial, pattern: .mirrored, position: 450, width: 600)))
        _ = clip.setKey(.gradientPosition, at: 0, value: 100)
        _ = clip.setKey(.gradientPosition, at: 0.3, value: 800)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let features = try AudioAnalyzer.analyze(url: audio)
        let output = directory.appendingPathComponent("gradient.mp4")
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
