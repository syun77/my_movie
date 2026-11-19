import AppKit
import AVFoundation
import Darwin
import Metal
import XCTest
@testable import MVStudio

final class SobelChromaticTests: XCTestCase {
    typealias Effect = ImageEffects.SobelChromatic

    func testClockModesTrimValidationAndAutomation() throws {
        var effect = Effect()
        XCTAssertTrue(effect.isValid)
        for time in [-0.5, 0, 0.1, 0.3, 1, 3.2] {
            let sample = effect.sample(at: time)
            let pulse = sin(2 * time)
            XCTAssertEqual(sample.mode, pulse > 0.4 && pulse < 0.8 ? .edge : .chromatic)
            XCTAssertEqual(sample.displacement, abs(pulse) * 32, accuracy: 1e-10)
        }
        for threshold in [0.4, 0.8] {
            let boundary = asin(threshold) / 2
            XCTAssertEqual(effect.sample(at: boundary - 1e-8).mode, threshold == 0.4 ? .chromatic : .edge)
            XCTAssertEqual(effect.sample(at: boundary + 1e-8).mode, threshold == 0.4 ? .edge : .chromatic)
        }
        effect.speed = 0
        XCTAssertEqual(effect.sample(at: 9).mode, .chromatic)
        XCTAssertEqual(effect.sample(at: 9).displacement, 0)
        effect.mode = .edge
        XCTAssertEqual(effect.sample(at: 9).mode, .edge)
        effect.speed = 150
        var clip = VisualClip(start: 1, end: 5, effects: ImageEffects(sobelChromatic: effect))
        let before = effect.sample(at: 2)
        clip.trimStart(to: 2)
        let after = try XCTUnwrap(clip.effects?.sobelChromatic).sample(at: 1)
        XCTAssertEqual(before.displacement, after.displacement)
        XCTAssertEqual(before.negativeOffset, after.negativeOffset)
        for parameter in Effect.parameters {
            let definition = try XCTUnwrap(parameter.effect)
            _ = clip.setKey(parameter, at: 0, value: definition.range.lowerBound)
            _ = clip.setKey(parameter, at: 2, value: definition.range.upperBound)
            let evaluated = try XCTUnwrap(clip.evaluatedEffects(at: 1))
            XCTAssertEqual(try XCTUnwrap(definition.read(evaluated)), (definition.range.lowerBound + definition.range.upperBound) / 2, accuracy: 1e-8)
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        effect.edgeWidth = .nan
        XCTAssertFalse(effect.isValid)
        effect = Effect(); effect.phaseOffset = .infinity
        XCTAssertFalse(effect.isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(Effect.Mode.self, from: Data("\"other\"".utf8)))
    }

    // This CPU oracle uses double precision bilinear sampling and an independent scalar Sobel sum.
    private func reference(_ pixels: [SIMD4<Float>], width: Int, height: Int, x: Int, y: Int,
                           effect: Effect, time: Double, canvas: CGSize, padding: Double) -> SIMD4<Double> {
        func read(_ x: Double, _ y: Double) -> SIMD4<Double> {
            let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
            var value = SIMD4<Double>.zero
            for dy in 0...1 { for dx in 0...1 {
                let px = ix + dx, py = iy + dy
                if px >= 0 && py >= 0 && px < width && py < height {
                    let weight = (dx == 0 ? 1 - fx : fx) * (dy == 0 ? 1 - fy : fy)
                    value += SIMD4<Double>(pixels[py * width + px]) * weight
                }
            } }
            return value
        }
        func brightness(_ color: SIMD4<Double>) -> Double {
            let carrier = max(color.w, min(1, max(color.x, max(color.y, color.z))))
            guard carrier > 0 else { return 0 }
            let weights = [0.3, 0.59, 0.11]
            return (0..<3).reduce(0) { value, channel in
                let linear = min(1, max(0, color[channel] / carrier))
                let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
                return value + weights[channel] * encoded * carrier
            }
        }
        let clock = (time + effect.phaseOffset) * effect.speed / 100
        let pulse = sin(2 * clock)
        let mode = effect.mode == .automatic ? (pulse > 0.4 && pulse < 0.8 ? Effect.Mode.edge : .chromatic) : effect.mode
        let scale = canvas.height / 1080
        let original = read(Double(x), Double(y))
        var result = SIMD4<Double>.zero
        if mode == .edge || mode == .combined {
            let offsets = [-1.8 * cos(6 * clock) * effect.edgeWidth * scale, 0, 3.2 * sin(6 * clock) * effect.edgeWidth * scale]
            let horizontal = [1.0, 0, -1, 2, 0, -2, 1, 0, -1]
            let vertical = [1.0, 2, 1, 0, 0, 0, -1, -2, -1]
            var gx = 0.0, gy = 0.0, coverage = original.w
            for row in 0..<3 { for column in 0..<3 {
                let sample = read(Double(x) + offsets[column], Double(y) + offsets[row])
                let value = brightness(sample)
                gx += horizontal[row * 3 + column] * value
                gy += vertical[row * 3 + column] * value
                coverage = max(coverage, sample.w)
            } }
            let edge = min(4, (gx * gx + gy * gy) * effect.edgeStrength / 100)
            let rgb = [effect.edgeColor.red, effect.edgeColor.green, effect.edgeColor.blue].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            result = SIMD4(rgb[0] * edge, rgb[1] * edge, rgb[2] * edge, coverage)
        }
        if mode == .chromatic || mode == .combined {
            let u = (Double(x) + 0.5 - padding) / canvas.width - 0.5
            let v = (Double(y) + 0.5 - padding) / canvas.height - 0.5
            let radius = min(1, hypot(u, v) / sqrt(0.5))
            let distance = pow(radius, 3) * abs(pulse) * effect.chromaticAmount * scale
            let red = read(Double(x) - distance / sqrt(2), Double(y) - distance / sqrt(2))
            let green = read(Double(x) - distance / sqrt(10), Double(y) + 3 * distance / sqrt(10))
            let blue = read(Double(x) + distance * 1.8 * cos(6 * clock) / sqrt(10), Double(y))
            result += SIMD4(red.x, green.y, blue.z, 0)
            result.w = max(result.w, max(red.w, max(green.w, blue.w)))
        }
        return original + (result - original) * (effect.amount / 100)
    }

    func testGPUAgainstCPUForAllModesTransparencyHDRAndPadding() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try SobelChromaticRenderer(device: device, library: SceneShaders.library(device: device))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 224, height = 140
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        for y in 12..<128 { for x in 10..<214 {
            let alpha: Float = x < 70 ? 0 : (x < 140 ? 0.35 : 1)
            let light: Float = x < 70 ? 1.5 : alpha
            pixels[y * width + x] = SIMD4(x % 13 < 6 ? light : 0.01, y % 11 < 5 ? light * 0.6 : 0,
                                          x > y ? light * 0.4 : 0, alpha)
        } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                 withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
        for mode in Effect.Mode.allCases {
            for time in [0.0, 0.3, 0.9] {
                var effect = Effect(); effect.mode = mode; effect.edgeWidth = 8; effect.chromaticAmount = 100
                effect.amount = time == 0.9 ? 37 : 100
                let commands = try XCTUnwrap(queue.makeCommandBuffer())
                let result = try renderer.render(source, effect: effect, localTime: time, canvas: CGSize(width: 192, height: 108),
                                                 padding: 16, output: output, commands: commands)
                XCTAssertTrue(result === output)
                commands.commit(); commands.waitUntilCompleted()
                XCTAssertEqual(commands.status, .completed, String(describing: commands.error))
                var actual = pixels
                actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 16,
                                                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                var maximumError = 0.0
                for y in stride(from: 0, to: height, by: 3) { for x in stride(from: 0, to: width, by: 3) {
                    let expected = reference(pixels, width: width, height: height, x: x, y: y, effect: effect, time: time,
                                             canvas: CGSize(width: 192, height: 108), padding: 16)
                    for channel in 0..<4 {
                        XCTAssertTrue(actual[y * width + x][channel].isFinite)
                        maximumError = max(maximumError, abs(Double(actual[y * width + x][channel]) - expected[channel]))
                    }
                } }
                // Hardware bilinear interpolation has finite fractional precision; the squared gradient amplifies its error.
                XCTAssertLessThan(maximumError, mode == .chromatic || (mode == .automatic && effect.sample(at: time).mode == .chromatic) ? 0.004 : 0.03,
                                  "\(mode) t=\(time)")
                XCTAssertEqual(actual[0], .zero)
            }
        }
        var disabled = Effect(); disabled.amount = 0
        XCTAssertTrue(try renderer.render(source, effect: disabled, localTime: 1, canvas: .zero, padding: 0,
                                          output: output, commands: XCTUnwrap(queue.makeCommandBuffer())) === source)
        disabled.amount = 100; disabled.isEnabled = false
        XCTAssertTrue(try renderer.render(source, effect: disabled, localTime: 1, canvas: .zero, padding: 0,
                                          output: output, commands: XCTUnwrap(queue.makeCommandBuffer())) === source)
    }

    func testChainRenderingCacheBypassAndOrder() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(shape: .init(), sobelChromatic: .init(mode: .combined, edgeWidth: 8, chromaticAmount: 100))
        clip.effects?.shape?.geometry.width = 1200
        clip.effects?.shape?.geometry.height = 600
        func snapshot() -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: canvas.target.width * canvas.target.height * 4)
            canvas.target.getBytes(&pixels, bytesPerRow: canvas.target.width * 4,
                                   from: MTLRegionMake2D(0, 0, canvas.target.width, canvas.target.height), mipmapLevel: 0)
            return pixels
        }
        try canvas.draw([(clip, 0)], time: 0.3)
        let first = snapshot()
        try canvas.save("/tmp/my-movie-sobel-preview.png")
        try canvas.draw([(clip, 0)], time: 0.9)
        XCTAssertNotEqual(first, snapshot())
        try canvas.draw([(clip, 0)], time: 0.3)
        XCTAssertTrue(first == snapshot(), "同時刻へのシーク結果")
        clip.effects?.sobelChromatic?.amount = 0
        try canvas.draw([(clip, 0)], time: 0.3)
        let plain = snapshot()
        XCTAssertNotEqual(first, plain)
        clip.effects?.sobelChromatic?.amount = 100
        clip.effects?.sobelChromatic?.isEnabled = false
        try canvas.draw([(clip, 0)], time: 0.3)
        XCTAssertTrue(plain == snapshot(), "無効時の原画一致")
        clip.effects?.sobelChromatic?.isEnabled = true
        let node = try XCTUnwrap(clip.effects?.nodes.last)
        clip.effects?.move(node.id, to: 0)
        try canvas.draw([(clip, 0)], time: 0.3)
        try canvas.save("/tmp/my-movie-sobel-reordered.png")
        let reordered = snapshot()
        let maximumError = zip(plain, reordered).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumError, 1, "透明入力の加工と余白による境界ラスタライズ差")
    }

    func testAutomaticModeMatchesExportedFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 19200))
        pcm.frameLength = 19200; pcm.floatChannelData![0].initialize(repeating: 0, count: 19200)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: pcm) }
        var clip = VisualClip(start: 0, end: 0.4, effects: ImageEffects(shape: .init(), sobelChromatic: .init(edgeWidth: 8)))
        clip.effects?.shape?.geometry.width = 1000
        clip.effects?.shape?.geometry.height = 600
        clip.effects?.shape?.color = .init(red: 1, green: 1, blue: 1)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let features = AudioFeatures(duration: 0.4, step: 0.1, frames: [], transientEvents: [TransientBand(): []])
        let output = directory.appendingPathComponent("sobel.mp4")
        try await VideoExporter.export(visuals: track, projectURL: ProjectStorage.projectURL(for: audio), audioURL: audio,
                                       features: features, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(),
                                       destination: output, cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first),
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let canvas = try EffectTestCanvas()
        var count = 0, edgeFrames = 0, chromaticFrames = 0
        while let sample = decoded.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try canvas.draw([(clip, 0)], time: time, video: true)
            let buffer = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for (x, y) in [(960, 540), (480, 540), (1440, 540), (960, 270), (960, 810)] {
                let expected = canvas.pixel(x, y)
                for channel in 0..<3 {
                    XCTAssertEqual(Double(base[y * stride + x * 4 + channel]), Double(expected[channel]), accuracy: 15,
                                   "frame \(count) at \(x),\(y)")
                }
            }
            if Effect().sample(at: time).mode == .edge { edgeFrames += 1 } else { chromaticFrames += 1 }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            count += 1
        }
        XCTAssertEqual(count, 12); XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(edgeFrames, 0); XCTAssertGreaterThan(chromaticFrames, 0)
    }

    func test1080pMultipleLayerCostAndProcessPeakMemory() throws {
        let canvas = try EffectTestCanvas()
        for count in [1, 3, 8] {
            let clips = (0..<count).map { index -> (VisualClip, Int) in
                let effect = Effect(mode: .combined, edgeStrength: 400, edgeWidth: 8, chromaticAmount: 100, speed: 400)
                let clip = VisualClip(start: 0, end: 2, effects: ImageEffects(shape: .init(), sobelChromatic: effect))
                return (clip, index)
            }
            var maximum = 0.0
            for frame in 0..<3 {
                try canvas.draw(clips, time: 0.3 + Double(frame) / 30)
                maximum = max(maximum, canvas.lastGPUMS)
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print("Sobel 1080p \(count) layers: GPU max \(maximum)ms, process peak RSS \(usage.ru_maxrss) bytes")
            XCTAssertGreaterThan(maximum, 0)
        }
    }

    @MainActor func testMusicCopyAndHistoryRetainNodeOwnership() throws {
        _ = NSApplication.shared
        var clip = VisualClip(start: 0, end: 2, effects: ImageEffects(sobelChromatic: .init()))
        clip.audioModulations[.sobelChromaticAmount] = AudioModulation(source: .beat, amount: 20)
        let evaluated = try XCTUnwrap(clip.evaluatedEffects(at: 0, settings: SceneSettings(bpm: 120)))
        XCTAssertEqual(evaluated.sobelChromatic?.chromaticAmount, 52)
        _ = clip.setKey(.sobelWidth, at: 0, value: 1)
        _ = clip.setKey(.sobelWidth, at: 1, value: 4)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        let editor = PlacementEditor(); _ = editor.view
        editor.duration = 10; editor.restoreTab(.visuals)
        editor.setAvailable(hasAudio: true, isBusy: false)
        let project = URL(fileURLWithPath: "/tmp/sobel-copy/project.mvproject")
        editor.visuals.load(track, projectURL: project)
        editor.timeline.onImageSelect?(clip.id, track.layers[0].id)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        editor.editClip(.copy, pasteboard: pasteboard)
        editor.editClip(.duplicate, pasteboard: pasteboard)
        let duplicate = try XCTUnwrap(editor.visuals.track.clips.last)
        XCTAssertEqual(duplicate.start, 2)
        XCTAssertEqual(duplicate.effects?.sobelChromatic, clip.effects?.sobelChromatic)
        XCTAssertNotEqual(duplicate.effects?.nodes.first?.id, clip.effects?.nodes.first?.id)
        XCTAssertNotEqual(duplicate.curve(.sobelWidth)?.keys.first?.id, clip.curve(.sobelWidth)?.keys.first?.id)
        XCTAssertEqual(duplicate.audioModulations[.sobelChromaticAmount], clip.audioModulations[.sobelChromaticAmount])
        let history = EditHistory(); history.reset(EditSnapshot(visuals: track))
        history.record(EditSnapshot(visuals: editor.visuals.track))
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertEqual(history.redo()?.visuals, editor.visuals.track)
    }

    @MainActor func testEditorModesNumbersAndPersistence() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(start: 0, end: 2)
        editor.load(clip, editable: true)
        var commits = 0
        editor.onCommit = { clip.effects = $0; commits += 1; editor.load(clip, editable: true) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "Sobel＋色収差"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(commits, 1)
        let mode = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.sobel.mode" })
        let fields = views.compactMap { $0 as? DragValueField }
        let content = try XCTUnwrap(mode.superview?.superview as? NSStackView)
        XCTAssertEqual(content.orientation, .vertical)
        for parameter in Effect.parameters {
            let field = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertTrue(field.isEnabled)
            XCTAssertNotNil(field.onCreateAutomation); XCTAssertNotNil(field.onEditMusic)
        }
        mode.selectItem(at: 2)
        XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
        XCTAssertEqual(clip.effects?.sobelChromatic?.mode, .chromatic)
        XCTAssertFalse(try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.sobelWidth" }).isEnabled)
        mode.selectItem(at: 1)
        XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
        XCTAssertFalse(try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.sobelChromaticAmount" }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(fields.first { $0.identifier?.rawValue == "visuals.value.sobelWidth" }).isEnabled)
        XCTAssertEqual(commits, 3)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        editor.load(clip, editable: false)
        XCTAssertFalse(mode.isEnabled)
    }
}
