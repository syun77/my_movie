import XCTest
import AppKit
import Metal
import CoreImage
import AVFoundation
@testable import MVStudio

final class SpineTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spine-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("model.json"), atlas = dir.appendingPathComponent("separate.atlas")
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("page.png"))
        try "page.png\nsize:4,4\nfilter:Linear,Linear\npma:true\nwhite\nbounds:0,0,4,4\n".write(to: atlas, atomically: true, encoding: .utf8)
        let root: [String: Any] = [
            "skeleton": ["spine": "4.3.26", "width": 200, "height": 100],
            "bones": [["name": "root"], ["name": "child", "parent": "root"]],
            "slots": [["name": "clip", "bone": "child", "attachment": "clip"], ["name": "shape", "bone": "child", "attachment": "shape"], ["name": "after", "bone": "root", "attachment": "after"]],
            "skins": [["name": "default", "attachments": [
                "clip": ["clip": ["type": "clipping", "end": "shape", "vertexCount": 6, "vertices": [0,0,100,0,100,40,40,40,40,100,0,100]]],
                "shape": ["shape": ["path": "white", "x": 50, "y": 50, "width": 100, "height": 100]],
                "after": ["after": ["path": "white", "x": 150, "y": 50, "width": 100, "height": 100]]
            ]]],
            "animations": ["move": ["bones": ["child": ["translatex": [["value": 0], ["time": 1, "value": 10]]]]],
                           "rotate": ["bones": ["child": ["rotate": [["value": 0], ["time": 1, "value": 90]]]]]]
        ]
        try JSONSerialization.data(withJSONObject: root, options: .sortedKeys).write(to: json)
        return (dir, json, atlas)
    }

    private func packet(_ layers: [VisualRenderLayer]) throws -> SpineDrawPacket {
        guard case let .spine(value) = try XCTUnwrap(layers.first).source else { throw StudioError.message("Missing Spine packet") }
        return value
    }

    func testConcaveClippingMotionSeekAndEndSlot() async throws {
        let (dir, json, atlas) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = SpinePoseProvider()
        let (descriptor, initial) = try await provider.inspect(skeleton: json, atlas: atlas)
        XCTAssertEqual(descriptor.exportVersion, "4.3.26")
        XCTAssertEqual(initial.pages.pages.count, 1)
        XCTAssertEqual(initial.pages.pages[0].bytes.prefix(4), Data([255,255,255,255]))
        let project = dir.appendingPathComponent("audio.mvproject")
        var track = VisualTrack(); let asset = track.register(url: json, projectURL: project, kind: .spine(descriptor))
        let result = try track.adding(assetID: asset, at: 0, slot: 1, duration: 3, grid: TimelineSnapGrid())
        track = result.track
        var clip = result.clip; clip.content = .spine(SpinePlayback(animationName: "move")); track = try track.updating(clip, slot: 1, duration: 3)
        func area(_ p: SpineDrawPacket) -> Double {
            stride(from: 0, to: p.indices.count, by: 3).reduce(0) { sum, i in
                let a = p.vertices[Int(p.indices[i])], b = p.vertices[Int(p.indices[i+1])], c = p.vertices[Int(p.indices[i+2])]
                return sum + Double(abs((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x))) / 2
            }
        }
        XCTAssertEqual(area(initial), 16400, accuracy: 0.1, "L-shaped clip area 6400 plus unmasked end-following area 10000")
        let first = try packet(await provider.layers(track: track, projectURL: project, time: 0.5, cancellation: nil))
        _ = try await provider.layers(track: track, projectURL: project, time: 0.9, cancellation: nil)
        let back = try packet(await provider.layers(track: track, projectURL: project, time: 0.5, cancellation: nil))
        XCTAssertEqual(first.vertices.map(\.x), back.vertices.map(\.x))
        XCTAssertEqual(first.vertices.map(\.y), back.vertices.map(\.y))
        XCTAssertEqual(area(first), 16400, accuracy: 0.1)
        XCTAssertTrue(first.vertices.contains { abs($0.x - 5) < 0.001 })
        let image = try SpineMetalRenderer.thumbnail(initial, maximumSize: 400)
        let pixels = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = pixels.data!.assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[((image.height-1-y)*image.width+x)*4+3] }
        XCTAssertEqual(alpha(70,70), 0, "Concave notch must stay transparent")
        XCTAssertEqual(alpha(20,20), 255)
        XCTAssertEqual(alpha(150,70), 255, "Mask must end after the end slot")
    }

    func testPersistenceTrimAndClipboardReferences() async throws {
        let (dir, json, atlas) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let (descriptor, _) = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas)
        let project = dir.appendingPathComponent("audio.mvproject")
        var track = VisualTrack(); let id = track.register(url: json, projectURL: project, kind: .spine(descriptor))
        track = try track.adding(assetID: id, at: 0, slot: 1, duration: 5, grid: TimelineSnapGrid()).track
        var clip = track.clips[0]; clip.content = .spine(SpinePlayback(animationName: "move", sourceIn: 3, loop: false))
        track = try track.updating(clip, slot: 1, duration: 5)
        track = try track.dragging(id: clip.id, part: .start, delta: 0.5, duration: 5, grid: TimelineSnapGrid())
        XCTAssertEqual(track.clips[0].content.sourceIn, 3.5)
        let file = ProjectFile(audioURL: dir.appendingPathComponent("audio.wav"), visuals: track, settings: SceneSettings(), projectURL: project)
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(file)); try decoded.validate()
        XCTAssertEqual(decoded.version, 8); XCTAssertEqual(decoded.visuals, track)
        let absolute = track.assets[0].kind.rebased(from: project, to: URL(fileURLWithPath: "/"))
        XCTAssertFalse(try XCTUnwrap(absolute.spineDescriptor).atlasReference.relative)
        XCTAssertEqual(absolute.spineDescriptor?.atlasReference.path, atlas.path)
        var invalid = track.clips[0]; invalid.content = .spine(SpinePlayback(animationName: "missing"))
        XCTAssertThrowsError(try track.updating(invalid, slot: 1, duration: 5))
    }

    func testMissingDependenciesAndExportSnapshot() async throws {
        let (dir, json, atlas) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = SpinePoseProvider(); let (descriptor, _) = try await provider.inspect(skeleton: json, atlas: atlas)
        let project = dir.appendingPathComponent("audio.mvproject")
        var track = VisualTrack(); let id = track.register(url: json, projectURL: project, kind: .spine(descriptor))
        track = try track.adding(assetID: id, at: 0, slot: 1, duration: 5, grid: TimelineSnapGrid()).track
        try await provider.prepare(track: track, projectURL: project, cancellation: nil)
        let before = try packet(await provider.layers(track: track, projectURL: project, time: 0.5, cancellation: nil))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("page.png"))
        let after = try packet(await provider.layers(track: track, projectURL: project, time: 0.5, cancellation: nil))
        XCTAssertEqual(before.pages.revision, after.pages.revision)
        XCTAssertEqual(before.vertices.map(\.x), after.vertices.map(\.x))
        do { _ = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas); XCTFail("Missing page must fail") } catch {}
        try "../outside.png\nsize:4,4\nwhite\nbounds:0,0,4,4\n".write(to: atlas, atomically: true, encoding: .utf8)
        do { _ = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas); XCTFail("Escaping path must fail") } catch {}
        let data = try String(contentsOf: json, encoding: .utf8).replacingOccurrences(of: "4.3.26", with: "4.2.00")
        try data.write(to: json, atomically: true, encoding: .utf8)
        do { _ = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas); XCTFail("Unsupported version must fail") } catch {}
        let cancellation = ExportCancellation(); cancellation.cancel()
        do { try await provider.prepare(track: track, projectURL: project, cancellation: cancellation); XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    @MainActor func testInspectorAnimationLoopSourceAndHistory() async throws {
        let (dir, json, atlas) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let (descriptor, _) = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas)
        let project = dir.appendingPathComponent("audio.mvproject")
        var track = VisualTrack(); let id = track.register(url: json, projectURL: project, kind: .spine(descriptor))
        let added = try track.adding(assetID: id, at: 0, slot: 1, duration: 5, grid: TimelineSnapGrid())
        let editor = PlacementEditor(); _ = editor.view; editor.restoreTab(.visuals); editor.duration = 5
        editor.visuals.load(added.track, projectURL: project); editor.setAvailable(hasAudio: true, isBusy: false)
        editor.timeline.onImageSelect?(added.clip.id, 1)
        func find(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0,id) }.first
        }
        let popup = try XCTUnwrap(find(editor.inspector, "visual.spine.animation") as? NSPopUpButton)
        let loop = try XCTUnwrap(find(editor.inspector, "visual.spine.loop") as? NSButton)
        let source = try XCTUnwrap(find(editor.inspector, "visual.sourceIn") as? NSTextField)
        let speed = try XCTUnwrap(find(editor.inspector, "visual.playbackSpeed") as? NSTextField)
        XCTAssertEqual(popup.numberOfItems, 2); XCTAssertTrue(speed.isHiddenOrHasHiddenAncestor)
        let history = EditHistory(); let settings = SceneSettings()
        history.reset(EditSnapshot(lyrics: LyricsTrack(), visuals: added.track, settings: settings))
        editor.visuals.onChange = { history.record(EditSnapshot(lyrics: LyricsTrack(), visuals: $0, settings: settings)) }
        popup.selectItem(withTitle: "rotate")
        editor.visuals.perform(NSSelectorFromString("changeSpine"))
        XCTAssertEqual(editor.visuals.track.clips[0].content.spinePlayback?.animationName, "rotate")
        loop.state = .off; editor.visuals.perform(NSSelectorFromString("changeSpine"))
        XCTAssertEqual(editor.visuals.track.clips[0].content.spinePlayback?.loop, false)
        source.stringValue = "3"; editor.visuals.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: source))
        XCTAssertEqual(editor.visuals.track.clips[0].content.sourceIn, 3)
        XCTAssertEqual(editor.visuals.track.clips[0].end, added.clip.end)
        XCTAssertNotNil(history.undo()); XCTAssertNotNil(history.redo())
        XCTAssertEqual(editor.currentTime, 0)
        editor.visuals.setAvailable(false)
    }

    func testExportSpineAndPreviewUseSameFrames() async throws {
        let (dir, json, atlas) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let (descriptor, _) = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas)
        let audio = dir.appendingPathComponent("audio.wav"), output = dir.appendingPathComponent("result.mp4")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8200)!
        buffer.frameLength = 8200
        for i in 0..<8200 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 8000) * 0.2) }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let project = dir.appendingPathComponent("audio.mvproject")
        var track = VisualTrack(); let id = track.register(url: json, projectURL: project, kind: .spine(descriptor))
        track.layers[0].clips = [VisualClip(assetID: id, start: 0, end: 1.025, content: .spine(SpinePlayback(animationName: "move")), audioModulations: [:])]
        let features = AudioFeatures(duration: 1.025, step: 0.1, frames: Array(repeating: Array(repeating: 0, count: 64), count: 12), transientEvents: [TransientBand(): []])
        var settings = SceneSettings(); settings.spectrum = false
        try await VideoExporter.export(visuals: track, projectURL: project, audioURL: audio, features: features, settings: settings, destination: output, cancellation: ExportCancellation(), progress: { _ in })
        let result = AVURLAsset(url: output)
        let videos = try await result.loadTracks(withMediaType: .video), audios = try await result.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let reader = try AVAssetReader(asset: result)
        let decoded = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let frames = VisualFrameProvider(), renderer = try MetalSceneRenderer()
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]; targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: targetDescriptor))
        var count = 0
        while let sample = decoded.copyNextSampleBuffer() {
            XCTAssertEqual(sample.presentationTimeStamp.seconds, Double(count)/30, accuracy: 1e-6)
            if [0,15,30].contains(count) {
                let time = Double(count)/30
                let layers = try await frames.layers(track: track, projectURL: project, time: time, allowMissingImages: false)
                let commands = try renderer.encode(visuals: layers, features: features, settings: settings, lyrics: LyricsTrack(), time: time, target: target, video: true)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in commands.addCompletedHandler { _ in continuation.resume() }; commands.commit() }
                let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)); CVPixelBufferLockBaseAddress(pixels, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
                for (x,y) in [(300,700),(700,300),(1500,300)] {
                    var expected = [UInt8](repeating: 0, count: 4)
                    target.getBytes(&expected, bytesPerRow: 4, from: MTLRegionMake2D(x,y,1,1), mipmapLevel: 0)
                    let actual = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self).advanced(by: y * CVPixelBufferGetBytesPerRow(pixels) + x*4)
                    for channel in 0..<3 { XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 15) }
                }
            }
            count += 1
        }
        XCTAssertEqual(count, 31); XCTAssertEqual(reader.status, .completed)
        let cancellation = ExportCancellation(); cancellation.cancel()
        let previous = try Data(contentsOf: output)
        do { try await VideoExporter.export(visuals: track, projectURL: project, audioURL: audio, features: features, settings: settings, destination: output, cancellation: cancellation, progress: { _ in }); XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: output), previous)
    }

    func testProvidedModelWeightedMasksAndThreeLayerRender() async throws {
        guard let path = ProcessInfo.processInfo.environment["MV_SPINE_SAMPLE_DIR"] else { throw XCTSkip("Set MV_SPINE_SAMPLE_DIR for the user's model") }
        let dir = URL(fileURLWithPath: path), json = dir.appendingPathComponent("testdata-blink-v2-neck-merged.json"), atlas = dir.appendingPathComponent("spine.atlas")
        let provider = SpinePoseProvider(); let (descriptor, _) = try await provider.inspect(skeleton: json, atlas: atlas)
        XCTAssertEqual(descriptor.animations.count, 4)
        let project = URL(fileURLWithPath: "/tmp/spine-sample.mvproject")
        var track = VisualTrack(); let id = track.register(url: json, projectURL: project, kind: .spine(descriptor))
        for i in 0..<3 { track.layers[i].clips = [VisualClip(assetID: id, start: 0, end: 5, content: .spine(SpinePlayback(animationName: "idle_natural_blink")), audioModulations: [:])] }
        let renderer = try MetalSceneRenderer()
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]; textureDescriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: textureDescriptor))
        var open: [Float] = []; var cpu: [Double] = []; var gpu: [Double] = []
        for time in [0.0, 1.533333, 1.566667, 1.633333, 1.7, 1.866667, 3.99, 4, 0.0] {
            let start = Date(); let layers = try await provider.layers(track: track, projectURL: project, time: time, cancellation: nil)
            cpu.append(Date().timeIntervalSince(start))
            XCTAssertEqual(layers.count, 3)
            let p = try packet(layers); XCTAssertGreaterThan(p.vertices.count, 10000)
            if time == 0 { if open.isEmpty { open = p.vertices.map(\.y) } else { XCTAssertEqual(open, p.vertices.map(\.y)) } }
            if time == 1.633333 { XCTAssertNotEqual(open, p.vertices.map(\.y)) }
            let commands = try renderer.encode(visuals: layers, features: nil, settings: SceneSettings(), lyrics: LyricsTrack(), time: time, target: target, video: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commands.addCompletedHandler { _ in continuation.resume() }; commands.commit()
            }
            XCTAssertEqual(commands.status, .completed)
            gpu.append(commands.gpuEndTime - commands.gpuStartTime)
            if time == 0 {
                var bytes = Data(count: 1920 * 1080 * 4)
                bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 1920 * 4, from: MTLRegionMake2D(0,0,1920,1080), mipmapLevel: 0) }
                let output = try XCTUnwrap(CGImage(width: 1920, height: 1080, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1920 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little), provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                try NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my-movie-spine-composite.png"))
            }
            if time == 0 || time == 1.633333 {
                let pimage = try SpineMetalRenderer.thumbnail(p, maximumSize: 1920)
                let data = NSBitmapImageRep(cgImage: pimage).representation(using: .png, properties: [:])
                try data?.write(to: URL(fileURLWithPath: time == 0 ? "/tmp/my-movie-spine-open.png" : "/tmp/my-movie-spine-blink.png"))
            }
        }
        print("SPINE_3x1080 cpu_max_ms=\(cpu.max()!*1000) gpu_max_ms=\(gpu.max()!*1000)")
    }
}
