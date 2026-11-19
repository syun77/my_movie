import AppKit
import Metal

import CoreImage
import AVFoundation
import XCTest
@testable import MVStudio

final class EffectChainTests: XCTestCase {
    func testNodeOwnedAutomationReorderTrimAndRoundTrip() throws {
        var effects = ImageEffects(mask: .init(), belowMask: .init(), snow: .init(seed: 42), colorCorrection: .init())
        let snow = try XCTUnwrap(effects.nodes.first { $0.kind == .snow })
        effects.move(snow.id, to: 0)
        var clip = VisualClip(start: 1, end: 5, effects: effects)
        let key = clip.setKey(.snowOpacity, at: 2, value: 40)
        _ = clip.setKey(.snowOpacity, at: 4, value: 80)
        clip.audioModulations[.snowDiameter] = AudioModulation(source: .beat, amount: 3)
        clip.automationRanges[.snowDiameter] = VisualClip.DisplayRange(lower: 2, upper: 64)
        _ = clip.setKey(.belowMaskX, at: 1, value: 400)
        _ = clip.setKey(.maskX, at: 1, value: 800)
        clip.effects?.move(snow.id, to: 2)
        XCTAssertEqual(clip.effects?.node(for: .snowOpacity)?.id, snow.id)
        XCTAssertEqual(clip.curve(.snowOpacity)?.keys.first?.id, key)
        XCTAssertEqual(clip.effects?.node(for: .snowOpacity)?.curves.count, 1)
        XCTAssertEqual(clip.effects?.node(for: .snowDiameter)?.audioModulations[.snowDiameter]?.amount, 3)
        XCTAssertEqual(clip.baseValue(.maskX), 960)
        XCTAssertNotEqual(clip.effects?.node(for: .maskX)?.id, clip.effects?.node(for: .belowMaskX)?.id)
        let value = clip.manualValue(.snowOpacity, at: 3)
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.manualValue(.snowOpacity, at: 3), value)
        XCTAssertEqual(clip.effects?.snow?.phaseOffset, 1)
        let data = try JSONEncoder().encode(clip)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: data), clip)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["effects"])
        let chain = try XCTUnwrap(json["effectChain"] as? [String: Any])
        XCTAssertNotNil(chain["nodes"])
        XCTAssertEqual((json["curves"] as? [Any])?.count, 0)
        var ids = Set<UUID>(); try clip.validateAnimation(ids: &ids)
        clip.effects?.snow = nil
        XCTAssertNil(clip.curve(.snowOpacity)); XCTAssertNil(clip.audioModulations[.snowDiameter])
        XCTAssertNil(clip.automationRanges[.snowDiameter])
    }

    func testDuplicateKindsAndCrossNodeAutomationRejected() throws {
        var effects = ImageEffects(blur: .init(), snow: .init(seed: 0))
        effects.nodes.append(EffectNode(payload: .blur(.init())))
        XCTAssertFalse(effects.isValid)
        effects.nodes.removeLast()
        effects.nodes[0].audioModulations[.snowOpacity] = AudioModulation(source: .beat, amount: 10)
        XCTAssertFalse(effects.isValid)
    }

    func testMigrationPreservesNodeIDsAndOutputMask() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v12", withExtension: "json", subdirectory: "Fixtures/Projects"))
        let data = try Data(contentsOf: fixture)
        let url = URL(fileURLWithPath: "/tmp/chain-migrate.mvproject")
        let first = try ProjectMigrator.read(data, at: url)
        let second = try ProjectMigrator.read(data, at: url)
        XCTAssertEqual(first.project.visuals, second.project.visuals)
        XCTAssertEqual(first.project.version, ProjectFile.currentVersion)
        var clip = try XCTUnwrap(first.project.visuals.clips.first)
        let ids = clip.effects?.nodes.map(\.id)
        clip.effects?.belowMask = .init()
        let restored = try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(restored.effects?.nodes.map(\.id), ids)
        XCTAssertEqual(restored.effects?.belowMask, clip.effects?.belowMask)
        XCTAssertThrowsError(try ProjectMigrator.read(Data("{\"version\":11}".utf8), at: url))
    }

    func testSnowBlurOrderAndBypass() throws {
        let canvas = try EffectTestCanvas(scale: 0.1)
        var clip = canvas.clip
        clip.effects = ImageEffects(snow: .init(count: 80, diameter: 32, seed: 9))
        clip.effects?.blur = .init(radius: 32)
        try canvas.draw([(clip, 1)])
        let blurred = snapshot(canvas)
        let blur = try XCTUnwrap(clip.effects?.nodes.first { $0.kind == .blur })
        clip.effects?.move(blur.id, to: 0)
        try canvas.draw([(clip, 1)])
        let sharp = snapshot(canvas)
        XCTAssertNotEqual(blurred, sharp)
        XCTAssertGreaterThan(sharp.max() ?? 0, blurred.max() ?? 0)
        clip.effects?.isBypassed = true
        try canvas.draw([(clip, 1)])
        let bypass = snapshot(canvas)
        clip.effects = nil
        try canvas.draw([(clip, 1)])
        XCTAssertEqual(bypass, snapshot(canvas))
    }

    func testMaskBloomOrderAndGeneratorOrientation() throws {
        let canvas = try EffectTestCanvas(scale: 0.1)
        var clip = canvas.clip
        clip.effects = ImageEffects(shape: .init(geometry: ShapeGeometry(width: 380, height: 380)), mask: .init(), bloom: .init(threshold: 0, radius: 60, intensity: 200))
        let mask = try XCTUnwrap(clip.effects?.nodes.first { $0.kind == .mask })
        clip.effects?.move(mask.id, to: 1)
        try canvas.draw([(clip, 1)])
        let outsideGlow = canvas.pixel(118, 54)[0]
        clip.effects?.move(mask.id, to: 2)
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(Int(outsideGlow), Int(canvas.pixel(118, 54)[0]) + 2)
        clip.effects = ImageEffects(shape: .init(geometry: ShapeGeometry(width: 200, height: 200, x: 960, y: 200), color: .init(red: 1, green: 0, blue: 0)))
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(canvas.pixel(96, 20)[2], 240)
        XCTAssertLessThan(canvas.pixel(96, 88)[2], 20)
    }

    func testAdditiveLightSurvivesDownstreamProcessing() throws {
        let canvas = try EffectTestCanvas(scale: 0.1)
        var clip = canvas.clip
        clip.effects = ImageEffects(lensFlare: .init(x: 960, y: 540))
        try canvas.draw([(clip, 1)])
        let light = snapshot(canvas).reduce(0) { $0 + Int($1) }
        clip.effects?.colorCorrection = .init()
        clip.effects?.binarization = .init(amount: 0)
        clip.effects?.blur = .init(radius: 0)
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(snapshot(canvas).reduce(0) { $0 + Int($1) }, light * 9 / 10)
        clip.effects?.bloom = .init(threshold: 0, radius: 8, intensity: 100)
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(snapshot(canvas).reduce(0) { $0 + Int($1) }, light)
        clip.effects?.blur?.radius = 16
        clip.effects?.colorCorrection?.saturation = 0
        try canvas.draw([(clip, 1)])
        XCTAssertGreaterThan(snapshot(canvas).reduce(0) { $0 + Int($1) }, 1000)
    }

    func testEveryGeneratorCanFeedAFilter() throws {
        let canvas = try EffectTestCanvas(scale: 0.05)
        for kind in EffectKind.allCases where ![.belowMask, .mask].contains(kind) {
            var clip = canvas.clip
            clip.effects = ImageEffects()
            clip.effects?.set(kind, payload: kind.initial)
            if kind != .blur { clip.effects?.blur = .init(radius: 4) }
            try canvas.draw([(clip, 1)], time: 0.5)
            let first = snapshot(canvas)
            try canvas.draw([(clip, 1)], time: 0.7)
            try canvas.draw([(clip, 1)], time: 0.5)
            XCTAssertEqual(first, snapshot(canvas), kind.title)
        }
    }

    @MainActor func testDragPreviewCommitAndCancel() throws {
        _ = NSApplication.shared
        let list = EffectChainList()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        list.nodes = ImageEffects(blur: .init(), snow: .init(seed: 0), colorCorrection: .init()).nodes
        list.editable = true
        var previews = 0, commits = 0, cancels = 0, target = -1
        list.onMove = { _, index, preview in target = index; if preview { previews += 1 } else { commits += 1 } }
        list.onCancel = { cancels += 1 }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: list.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        list.mouseDown(with: try event(.leftMouseDown, 8, 10))
        list.mouseDragged(with: try event(.leftMouseDragged, 8, 78))
        XCTAssertEqual(commits, 0); XCTAssertEqual(previews, 1)
        list.mouseUp(with: try event(.leftMouseUp, 8, 78))
        XCTAssertEqual(commits, 1); XCTAssertEqual(target, 2)
        list.mouseDown(with: try event(.leftMouseDown, 8, 10))
        list.mouseDragged(with: try event(.leftMouseDragged, 8, 78))
        list.cancelOperation(nil)
        list.mouseUp(with: try event(.leftMouseUp, 8, 78))
        XCTAssertEqual(commits, 1); XCTAssertEqual(cancels, 1)
        list.mouseDown(with: try event(.leftMouseDown, 8, 10))
        list.mouseDragged(with: try event(.leftMouseDragged, 8, 78))
        list.mouseUp(with: try event(.leftMouseUp, -20, 78))
        XCTAssertEqual(commits, 1); XCTAssertEqual(cancels, 2)
    }

    @MainActor func testInspectorReorderHistoryBypassAndNodeHeights() throws {
        _ = NSApplication.shared
        let editor = VisualEditor(); _ = editor.view
        editor.duration = 5; editor.currentTime = 1; editor.setAvailable(true)
        var clip = VisualClip(start: 0, end: 4, effects: ImageEffects(blur: .init(), snow: .init(seed: 42)))
        _ = clip.setKey(.snowOpacity, at: 0, value: 30)
        let originalNodes = try XCTUnwrap(clip.effects).nodes
        var track = VisualTrack(); track.layers[0].clips = [clip]
        editor.commit(track, selectedID: clip.id)
        let history = EditHistory(); history.reset(EditSnapshot(visuals: track))
        var commits = 0
        editor.onChange = { commits += 1; history.record(EditSnapshot(visuals: $0)) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let list = try XCTUnwrap(all(editor.view).compactMap { $0 as? EffectChainList }.first)
        let snow = try XCTUnwrap(originalNodes.first { $0.kind == .snow })
        let menu = try XCTUnwrap(list.menuForNode?(snow.id))
        let up = try XCTUnwrap(menu.item(withTitle: "上へ移動"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(up.action), to: up.target, from: up))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.nodes.first?.id, snow.id)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.snowOpacity)?.keys.first?.id, clip.curve(.snowOpacity)?.keys.first?.id)
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertEqual(history.redo()?.visuals, editor.track)
        let bypass = try XCTUnwrap(all(editor.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "visuals.effects.bypass" })
        bypass.state = .on; XCTAssertTrue(bypass.sendAction(bypass.action, to: bypass.target))
        XCTAssertEqual(commits, 2); XCTAssertEqual(editor.track.clip(clip.id)?.effects?.isBypassed, true)
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.nodes.first?.id, snow.id)
        var heights = TimelineHeights()
        heights.setHeight(105, for: .automation(testLayerID(1), .snowOpacity), nodeID: snow.id)
        XCTAssertEqual(heights.height(.automation(testLayerID(1), .snowOpacity), nodeID: snow.id), 105)
        XCTAssertEqual(heights.height(.automation(testLayerID(1), .snowOpacity), nodeID: UUID()), 62)
        XCTAssertTrue(heights.isValid)
        XCTAssertEqual(try JSONDecoder().decode(TimelineHeights.self, from: JSONEncoder().encode(heights)), heights)
    }

    func testReorderedChainMatchesMP4Frames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
        pcm.frameLength = 9600; pcm.floatChannelData![0].initialize(repeating: 0, count: 9600)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        var clip = VisualClip(start: 0, end: 0.2, effects: ImageEffects(shape: .init(geometry: ShapeGeometry(width: 1000, height: 600), color: .init(red: 1, green: 0, blue: 0)), colorCorrection: .init(saturation: 0)))
        let color = try XCTUnwrap(clip.effects?.nodes.first { $0.kind == .colorCorrection })
        clip.effects?.move(color.id, to: 0)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let features = AudioFeatures(duration: 0.2, step: 0.1, frames: [], transientEvents: [TransientBand(): []])
        let output = directory.appendingPathComponent("chain.mp4")
        try await VideoExporter.export(visuals: track, projectURL: ProjectStorage.projectURL(for: audio), audioURL: audio, features: features,
                                       settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), destination: output,
                                       cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let canvas = try EffectTestCanvas()
        try canvas.draw([(clip, 1)], time: 0, video: true)
        let expected = canvas.pixel(960, 540)
        XCTAssertGreaterThan(expected[2], 240); XCTAssertLessThan(expected[1], 15)
        var count = 0
        while let sample = decoded.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let offset = 540 * CVPixelBufferGetBytesPerRow(buffer) + 960 * 4
            for channel in 0..<3 { XCTAssertEqual(Double(base[offset + channel]), Double(expected[channel]), accuracy: 15) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            count += 1
        }
        XCTAssertEqual(count, 6); XCTAssertEqual(reader.status, .completed)
    }

    private func snapshot(_ canvas: EffectTestCanvas) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: canvas.target.width * canvas.target.height * 4)
        canvas.target.getBytes(&bytes, bytesPerRow: canvas.target.width * 4,
                              from: MTLRegionMake2D(0, 0, canvas.target.width, canvas.target.height), mipmapLevel: 0)
        return bytes.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
    }
}

private func testLayerID(_ index: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 100))! }
