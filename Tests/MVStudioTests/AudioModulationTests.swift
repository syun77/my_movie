import AppKit
import AVFoundation
import XCTest
@testable import MVStudio

final class AudioModulationTests: XCTestCase {
    func testEveryNoteDenominatorUsesQuarterNoteBPMAndSharedOrigin() throws {
        let settings = SceneSettings(bpm: 137.3, beatOffset: 0.173)
        for n in 1...16 {
            var modulation = AudioModulation(source: .beat, amount: 20, beatNoteDenominator: n)
            let period = 240 / 137.3 / Double(n)
            XCTAssertTrue(modulation.isValid(for: .x))
            XCTAssertEqual(BeatTiming.period(bpm: settings.bpm, denominator: n), period, accuracy: 1e-12)
            XCTAssertNil(BeatTiming.latest(at: settings.beatOffset - 1e-8, settings: settings, denominator: n))
            for index in [0, 1, 7, 10000] {
                let event = settings.beatOffset + Double(index) * period
                XCTAssertEqual(modulation.signal(at: event, settings: settings, features: nil), 1, accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(BeatTiming.latest(at: event + period * 0.9, settings: settings, denominator: n)), event, accuracy: 1e-9)
                if index > 0 { XCTAssertLessThan(modulation.signal(at: event - 1e-7, settings: settings, features: nil), 0.9) }
            }
            modulation.beatNoteDenominator = 0; XCTAssertFalse(modulation.isValid(for: .x))
            modulation.beatNoteDenominator = 17; XCTAssertFalse(modulation.isValid(for: .x))
        }
        XCTAssertEqual(BeatTiming.period(bpm: 120, denominator: 12), 1.0 / 6, accuracy: 1e-12)
    }

    func testAddRelativeClampingRoundingAndIndependentBands() throws {
        let low = TransientBand(kind: .low), high = TransientBand(kind: .high)
        let features = AudioFeatures(duration: 10, step: 1, frames: [], transientEvents: [low: [1], high: [1.03]])
        var clip = VisualClip(assetID: UUID(), start: 0.5, end: 5, audioModulations: [:])
        clip.setBaseValue(120, for: .scale)
        clip.audioModulations[.scale] = AudioModulation(blend: .relative, amount: 8, transientBand: low)
        clip.audioModulations[.x] = AudioModulation(amount: -40, transientBand: high)
        let settings = SceneSettings()
        func value(_ p: ImageParameter, _ t: Double) -> Double { ParameterEvaluator.value(p, clip: clip, at: t, settings: settings, features: features) }
        XCTAssertEqual(value(.scale, 1), 129.6, accuracy: 1e-9)
        XCTAssertEqual(value(.x, 1), 0)
        XCTAssertEqual(value(.x, 1.03), -40)
        XCTAssertEqual(value(.scale, 1.15), 121.2, accuracy: 1e-9)
        XCTAssertEqual(value(.scale, 1.31), 120)
        clip.audioModulations[.opacity] = AudioModulation(amount: -140, transientBand: low)
        XCTAssertEqual(value(.opacity, 1), 0)
        clip.effects = ImageEffects(particles: .init(seed: 1))
        clip.audioModulations[.particlesCount] = AudioModulation(amount: 1.5, transientBand: low)
        XCTAssertEqual(clip.evaluatedEffects(at: 1, features: features)?.particles?.count,
                       (clip.baseValue(.particlesCount) + 1.5).rounded())
        clip.audioModulations[.scale]?.amount = -100
        XCTAssertEqual(value(.scale, 1), 0.1)
        XCTAssertEqual(clip.audioModulations[.x]?.signal(at: 1.03, settings: settings, features: nil), 0)
    }

    func testKeysTrimmingRangesAndPersistence() throws {
        let settings = SceneSettings(bpm: 120, beatOffset: 0)
        var clip = VisualClip(assetID: UUID(), start: 1, end: 4)
        clip.audioModulations[.scale]?.source = .beat
        clip.audioModulations[.scale]?.beatNoteDenominator = 12
        clip.automationRanges[.scale] = .init(lower: 50, upper: 150)
        XCTAssertNil(clip.curve(.scale))
        XCTAssertEqual(clip.displayCurve(.scale)?.minimum, 50)
        let first = clip.setKey(.scale, at: 1, value: 100)
        let last = clip.setKey(.scale, at: 3, value: 140)
        XCTAssertNil(clip.automationRanges[.scale])
        let before = ParameterEvaluator.value(.scale, clip: clip, at: 2, settings: settings, features: nil)
        XCTAssertEqual(before, 129.6, accuracy: 1e-9)
        clip.trimStart(to: 1.7)
        XCTAssertEqual(ParameterEvaluator.value(.scale, clip: clip, at: 2, settings: settings, features: nil), before)
        let encoded = try JSONEncoder().encode(clip)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: encoded), clip)
        clip.removeKey(first, parameter: .scale); clip.removeKey(last, parameter: .scale)
        XCTAssertNil(clip.curve(.scale)); XCTAssertNotNil(clip.displayCurve(.scale))
        var ids = Set<UUID>(); try clip.validateAnimation(ids: &ids)
        clip.removeAudioAndKeys(.scale)
        XCTAssertNil(clip.displayCurve(.scale)); XCTAssertEqual(clip.baseValue(.scale), 140)
    }

    func testRemovedEffectsAndEmittersRemoveOrRenumberSync() throws {
        var clip = VisualClip(assetID: UUID(), start: 0, end: 4)
        clip.effects = ImageEffects(particles: .init(seed: 1))
        clip.effects?.particles?.emitters.append(.init())
        clip.audioModulations[.emitter0X] = AudioModulation(amount: 20)
        clip.audioModulations[.emitter1X] = AudioModulation(amount: 30)
        clip.automationRanges[.emitter1X] = .init(lower: -10, upper: 50)
        clip.removeEmitterAutomation(at: 0)
        XCTAssertEqual(clip.audioModulations[.emitter0X]?.amount, 30)
        XCTAssertEqual(clip.automationRanges[.emitter0X]?.upper, 50)
        XCTAssertNil(clip.audioModulations[.emitter1X])
        clip.removeAudioAndKeys(.emitter0X)
        XCTAssertNil(clip.audioModulations[.emitter0X])
    }

    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let rate = 48000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for index in 0..<48000 {
            let t = Double(index) / rate
            var value = 0.0
            for (start, frequency) in [(0.1, 80.0), (0.4, 1000.0), (0.43, 8000.0)] where t >= start && t < start + 0.04 {
                let ramp = 0.5 * (1 - cos(.pi * min(1, min(t - start, start + 0.04 - t) / 0.005)))
                value += 0.5 * ramp * sin(2 * .pi * frequency * (t - start))
            }
            buffer.floatChannelData![0][index] = Float(value)
            buffer.floatChannelData![1][index] = -Float(value)
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        return url
    }

    func testBandDetectionAndCustomFilterEquality() throws {
        let url = try audioFile(); defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let custom = TransientBand(kind: .custom, lowerHz: 180, upperHz: 2400)
        let bands = TransientDetector.fixedBands + [custom]
        let events = try TransientDetector.detect(in: file, bands: bands)
        XCTAssertEqual(events[custom], events[TransientBand(kind: .mid)])
        XCTAssertTrue(events[TransientBand(kind: .low), default: []].contains { abs($0 - 0.1) <= 0.015 })
        XCTAssertTrue(events[TransientBand(kind: .mid), default: []].contains { abs($0 - 0.4) <= 0.01 })
        XCTAssertTrue(events[TransientBand(kind: .high), default: []].contains { abs($0 - 0.43) <= 0.01 }, "events: \(events)")
        XCTAssertFalse(events[TransientBand(kind: .high), default: []].contains { abs($0 - 0.1) <= 0.01 })
        XCTAssertNil(TransientBand(kind: .high).bounds(sampleRate: 4000))
        XCTAssertNil(TransientBand(kind: .custom, lowerHz: 10000, upperHz: 20000).bounds(sampleRate: 16000))
        XCTAssertFalse(TransientBand(kind: .custom, lowerHz: 200, upperHz: 100).isValid)
        XCTAssertThrowsError(try TransientDetector.detect(in: file) { throw CancellationError() })
    }

    func testSharedAnalysisCacheAndCancellation() async throws {
        let url = try audioFile(); defer { try? FileManager.default.removeItem(at: url) }
        let features = try AudioAnalyzer.analyze(url: url)
        let service = TransientAnalysisService()
        let custom = TransientBand(kind: .custom, lowerHz: 3000, upperHz: 12000)
        async let a = service.prepare(features, url: url, bands: [custom])
        async let b = service.prepare(features, url: url, bands: [custom])
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.events(for: custom), second.events(for: custom))
        XCTAssertTrue(first.events(for: custom).contains { abs($0 - 0.43) <= 0.01 }, "events: \(first.events(for: custom))")
        let cached = try await service.prepare(features, url: url, bands: [custom])
        XCTAssertEqual(cached.events(for: custom), first.events(for: custom))
        let runningToken = ExportCancellation()
        let other = TransientBand(kind: .custom, lowerHz: 4000, upperHz: 11000)
        let running = Task { try await service.prepare(features, url: url, bands: [other], cancellation: runningToken) }
        try await Task.sleep(nanoseconds: 10_000_000)
        runningToken.cancel()
        do { _ = try await running.value; XCTFail("Expected running analysis cancellation") }
        catch is CancellationError { }
        let retried = try await service.prepare(features, url: url, bands: [other])
        XCTAssertNotNil(retried.transientEvents[other])
        let token = ExportCancellation(); token.cancel()
        do { _ = try await service.prepare(features, url: url, bands: [custom], cancellation: token); XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testCombinedPlotPreservesManualAndAudioJumps() throws {
        var clip = VisualClip(assetID: UUID(), start: 0, end: 3, audioModulations: [:])
        _ = clip.setKey(.x, at: 0, value: 0)
        _ = clip.setKey(.x, at: 1, value: 100)
        var curve = try XCTUnwrap(clip.curve(.x)); curve.keys[1].interpolation = .hold; clip.setCurve(curve)
        clip.audioModulations[.x] = AudioModulation(source: .beat, amount: 40, releaseSeconds: 0.1)
        let samples = ParameterEvaluator.plotSamples(.x, clip: clip, from: 0, through: 2, steps: 100, settings: SceneSettings(), features: nil)
        let jump = samples.filter { $0.0 == 1 }.map { $0.1 }
        XCTAssertEqual(jump.count, 2)
        XCTAssertEqual(jump.first, 0)
        XCTAssertEqual(jump.last, 140)
        for sample in samples where ![0.5, 1, 1.5, 2].contains(sample.0) {
            XCTAssertEqual(sample.1, ParameterEvaluator.value(.x, clip: clip, at: sample.0, settings: SceneSettings(), features: nil))
        }
    }

    @MainActor func testInspectorMenuBeatNumbersPreviewAndSyncOnlyLane() throws {
        _ = NSApplication.shared
        let editor = VisualEditor(); _ = editor.view
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        editor.timeline = timeline; timeline.visualMode = true; timeline.duration = 10
        var track = VisualTrack()
        let projectURL = URL(fileURLWithPath: "/tmp/audio-modulation.mvproject")
        let asset = track.register(url: URL(fileURLWithPath: "/tmp/sync.png"), projectURL: projectURL)
        let added = try track.adding(assetID: asset, at: 0, slot: 1, duration: 10, grid: TimelineSnapGrid())
        track = added.track
        editor.duration = 10; editor.load(track, projectURL: projectURL); editor.setAvailable(true)
        timeline.onImageSelect?(added.clip.id, 1)
        XCTAssertNotNil(editor.track.clip(added.clip.id)?.displayCurve(.scale))
        let fields = DragValueField.fields(in: editor.view)
        let scale = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.scale" })
        XCTAssertTrue(scale.hasMusic); XCTAssertFalse(scale.hasAutomation)
        scale.setFrameSize(NSSize(width: 90, height: 24))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: scale.convert(NSPoint(x: 11, y: 12), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(scale.menu(for: event)?.items.map(\.title), ["オートメーションを作成", "音楽同期を編集…", "音楽同期を削除"])
        var commits = 0
        editor.onChange = { _ in commits += 1 }
        var clip = try XCTUnwrap(editor.track.clip(added.clip.id)); clip.audioModulations[.scale]?.source = .beat
        editor.musicEditor.onCommit?(.scale, clip.audioModulations[.scale])
        let denominator = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "audioModulation.denominator" })
        for n in 1...16 {
            denominator.integerValue = n; XCTAssertTrue(denominator.sendAction(denominator.action, to: denominator.target))
            XCTAssertEqual(editor.track.clip(clip.id)?.audioModulations[.scale]?.beatNoteDenominator, n)
        }
        denominator.stringValue = "1e100"; _ = denominator.sendAction(denominator.action, to: denominator.target)
        XCTAssertEqual(editor.track.clip(clip.id)?.audioModulations[.scale]?.beatNoteDenominator, 16)
        let before = editor.track
        XCTAssertEqual(denominator.doubleValue, 16)
        XCTAssertEqual(denominator.onDragStart?(), true)
        denominator.onDragChange?(-5)
        XCTAssertEqual(editor.track, before)
        XCTAssertTrue(editor.cancelValueDrag())
        XCTAssertEqual(editor.track, before)
        XCTAssertGreaterThan(commits, 10)
        var custom = AudioModulation(blend: .relative, amount: 8, transientBand: TransientBand(kind: .custom, lowerHz: 300, upperHz: 400))
        editor.musicEditor.onCommit?(.scale, custom)
        let upper = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "audioModulation.upper" })
        upper.doubleValue = 180; _ = upper.sendAction(upper.action, to: upper.target)
        XCTAssertEqual(editor.track.clip(clip.id)?.audioModulations[.scale]?.transientBand.upperHz, 400)
        upper.onReset?()
        custom.transientBand.lowerHz = 40; custom.transientBand.upperHz = 180
        XCTAssertEqual(editor.track.clip(clip.id)?.audioModulations[.scale], custom)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        editor.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
        editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-audio-inspector.png"))
        window.close()
    }
}
