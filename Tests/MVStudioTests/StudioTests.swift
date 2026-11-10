import AppKit
import XCTest
import AVFoundation
import ImageIO
@testable import MVStudio

final class StudioTests: XCTestCase {
    func testTransientZoomAndSpectrumInterpolation() {
        let features = AudioFeatures(duration: 1, step: 0.5, frames: [[0, 1], [1, 0]], transientTimes: [0.12, 0.28])
        var clip = ImageClip(assetID: UUID(), start: 0, end: 1, pulseAmount: 0.1)
        XCTAssertEqual(clip.scale(at: 0.119, settings: SceneSettings(), transientPulse: features.transientPulse(at: 0.119)), 1)
        XCTAssertEqual(clip.scale(at: 0.28, settings: SceneSettings(), transientPulse: features.transientPulse(at: 0.28)), 1.1, accuracy: 0.0001)
        XCTAssertEqual(clip.scale(at: 0.43, settings: SceneSettings(), transientPulse: features.transientPulse(at: 0.43)), 1.0125, accuracy: 0.0001)
        XCTAssertEqual(clip.scale(at: 0.6, settings: SceneSettings(), transientPulse: features.transientPulse(at: 0.6)), 1)
        XCTAssertEqual(features.transientPulse(at: 0.12), 1, "シーク順によらず評価する")
        clip.automaticAnimation = .off
        XCTAssertEqual(clip.scale(at: 0.28, settings: SceneSettings(), transientPulse: features.transientPulse(at: 0.28)), 1)
        XCTAssertEqual(features.bands(at: 0.25, count: 2), [0.5, 0.5])
        XCTAssertEqual(features.bands(at: 1, count: 32), Array(repeating: 0, count: 32))
        XCTAssertEqual(features.bandEdges(at: 0, count: 2), [0, 0.5, 1])
        XCTAssertEqual(features.bandEdges(at: 0.25, count: 2), [0.5, 0.5, 0.5])
        XCTAssertEqual(features.bandEdges(at: 1, count: 32), Array(repeating: 0, count: 33))
    }

    func testSpectrumRenderingUsesStyleAndBandCount() throws {
        func columns(settings: SceneSettings) throws -> [Int] {
            let image = try renderSpectrum(settings: settings, value: 0.7)
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            return (0..<image.width).map { x in
                (0..<image.height).count { y in
                    isRed(pixel(in: image, data: pixels, x: x, y: y))
                }
            }
        }

        var settings = SceneSettings(spectrumStyle: SpectrumStyle(color: RGBColor(red: 1, green: 0, blue: 0)))
        for resolution in SpectrumStyle.Resolution.allCases {
            settings.spectrumStyle.resolution = resolution
            let bars = try columns(settings: settings)
            let starts = bars.indices.count { bars[$0] > 10 && ($0 == 0 || bars[$0 - 1] <= 10) }
            XCTAssertEqual(starts, resolution.rawValue)
        }
        settings.spectrumStyle.shape = .line
        let line = try columns(settings: settings)
        XCTAssertGreaterThan(line.count { $0 > 0 }, 500)
        XCTAssertLessThan(line.max() ?? 0, 4)
        settings.spectrum = false
        XCTAssertTrue(try columns(settings: settings).allSatisfy { $0 == 0 })
    }

    func testSpectrumLayoutPositionsAndSizesBothShapesOverClearBackground() throws {
        let layout = SpectrumLayout(x: 300, y: 180, width: 600, height: 120, barGap: 50)
        var settings = SceneSettings(spectrumStyle: SpectrumStyle(color: RGBColor(red: 1, green: 0, blue: 0),
                                                                resolution: .minimal, layout: layout))
        func sample(_ settings: SceneSettings) throws -> (Int, Int) -> [UInt8] {
            let image = try renderSpectrum(settings: settings, value: 0.5)
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            return { self.pixel(in: image, data: pixels, x: $0, y: $1) }
        }
        var hidden = settings
        hidden.spectrum = false
        let background = try sample(hidden)
        let bars = try sample(settings)
        XCTAssertTrue(isRed(bars(110, 90)))
        XCTAssertTrue(isRed(bars(165, 90)))
        XCTAssertEqual(bars(142, 90), background(142, 90))
        XCTAssertEqual(bars(110, 70), background(110, 70))
        XCTAssertEqual(bars(95, 90), background(95, 90))
        XCTAssertEqual(bars(310, 90), background(310, 90))
        XCTAssertEqual(bars(10, 320), background(10, 320), "下部の映像を暗くしない")

        settings.spectrumStyle.layout.barGap = 0
        let noGap = try sample(settings)
        XCTAssertTrue(isRed(noGap(142, 90)))

        settings.spectrumStyle.shape = .line
        let line = try sample(settings)
        XCTAssertTrue(isRed(line(142, 80)))
        XCTAssertEqual(line(142, 90), background(142, 90))
        XCTAssertEqual(line(310, 80), background(310, 80))
    }

    func testSpectrumBarsSlopeBetweenBandBoundaries() throws {
        let layout = SpectrumLayout(x: 300, y: 180, width: 600, height: 120, barGap: 0)
        let style = SpectrumStyle(color: RGBColor(red: 1, green: 0, blue: 0), resolution: .minimal, layout: layout)
        var levels = Array(repeating: Float(0), count: 64)
        levels[0] = 1
        levels[16] = 0.2
        levels[31] = 0.8
        levels[32] = 1

        let image = try renderSpectrum(settings: SceneSettings(spectrumStyle: style), bands: levels)
        let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
        func hasBar(x: Int, y: Int) -> Bool { isRed(pixel(in: image, data: pixels, x: x, y: y)) }

        XCTAssertTrue(hasBar(x: 105, y: 80))
        XCTAssertFalse(hasBar(x: 145, y: 80), "最初のバーは右下がり")
        XCTAssertFalse(hasBar(x: 155, y: 80))
        XCTAssertTrue(hasBar(x: 195, y: 80), "2本目のバーは右上がり")
        XCTAssertTrue(hasBar(x: 199, y: 80))
        XCTAssertTrue(hasBar(x: 200, y: 80), "余白0%では隣接する上辺が境界でつながる")
    }

    private func renderSpectrum(settings: SceneSettings, value: Float) throws -> CGImage {
        try renderSpectrum(settings: settings, bands: Array(repeating: value, count: SpectrumStyle.Resolution.high.rawValue))
    }

    private func renderSpectrum(settings: SceneSettings, bands: [Float]) throws -> CGImage {
        let size = CGSize(width: 640, height: 360)
        let features = AudioFeatures(duration: 1, step: 1, frames: [bands], transientTimes: [])
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                             bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        SceneRenderer.draw(in: context, size: size, features: features, settings: settings, time: 0)
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(in image: CGImage, data: Data, x: Int, y: Int) -> [UInt8] {
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }

    private func isRed(_ rgba: [UInt8]) -> Bool {
        rgba[0] > 100 && rgba[1] < 60 && rgba[2] < 60
    }

    func testAnalysisAndAudioVideoExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.wav")
        let rate = 48000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let count: AVAudioFrameCount = 48000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) {
            let time = Double(index) / rate
            let tone = Float(sin(2 * .pi * 1000 * time)) * 0.5
            let attack: Float = (0.316..<0.326).contains(time) || (0.747..<0.757).contains(time)
                ? Float(sin(2 * .pi * 7000 * time)) * 0.3 : 0
            let value = tone + attack
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = -value
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let features = try AudioAnalyzer.analyze(url: url)
        XCTAssertEqual(features.duration, 1, accuracy: 0.001)
        XCTAssertEqual(features.transientTimes.count, 3, "持続音は開始時だけ反応し、逆相でも打音を検出: \(features.transientTimes)")
        for (actual, expected) in zip(features.transientTimes, [0.0, 0.316, 0.747]) {
            XCTAssertEqual(actual, expected, accuracy: 0.006)
        }
        XCTAssertTrue(features.frames.flatMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(features.frames.allSatisfy { $0.count == 64 })
        let middle = features.bands(at: 0.5, count: 32)
        let peak = middle.indices.max(by: { middle[$0] < middle[$1] })!
        XCTAssertTrue((16...19).contains(peak), "1kHz peak: \(peak)")
        XCTAssertGreaterThan(middle[peak], 0.4, "逆相ステレオでも信号を検出")
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let output = directory.appendingPathComponent("result.mp4")
        let lyrics = LyricsTrack(clips: [LyricClip(start: 0, end: 1, text: "歌詞の縁取り")], outlineWidth: 6, outlineColor: RGBColor(red: 0, green: 1, blue: 0))
        let imageURL = directory.appendingPathComponent("source.png")
        let imageDestination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(imageDestination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(imageDestination))
        let projectURL = ProjectStorage.projectURL(for: url)
        var images = ImageTrack()
        let assetID = images.register(url: imageURL, projectURL: projectURL)
        images.layers[0].clips = [ImageClip(assetID: assetID, start: 0, end: 1, pulseAmount: 0.25)]
        let overlayURL = directory.appendingPathComponent("overlay.png")
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let overlayDestination = CGImageDestinationCreateWithURL(overlayURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(overlayDestination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(overlayDestination))
        let overlayID = images.register(url: overlayURL, projectURL: projectURL)
        var animated = ImageClip(assetID: overlayID, start: 0.5, end: 0.8, automaticAnimation: .off)
        _ = animated.setKey(.x, at: 0.6, value: 0)
        _ = animated.setKey(.x, at: 0.7, value: 600)
        images.layers[2].clips = [animated]
        let layout = SpectrumLayout(x: 300, y: 650, width: 900, height: 180)
        let style = SpectrumStyle(shape: .line, color: RGBColor(red: 1, green: 0, blue: 1), resolution: .medium, layout: layout)
        try await VideoExporter.export(images: images, projectURL: projectURL, audioURL: url, features: features, settings: SceneSettings(spectrumStyle: style), lyrics: lyrics, destination: output, cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 1.0 / 30)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        XCTAssertEqual(frame.width, 1920); XCTAssertEqual(frame.height, 1080)
        let naturalSize = try await videos[0].load(.naturalSize)
        let frameRate = try await videos[0].load(.nominalFrameRate)
        XCTAssertEqual(naturalSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(frameRate, 30, accuracy: 0.01)
        let decoded = CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        decoded.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let pixels = decoded.data!.assumingMemoryBound(to: UInt8.self)
        let greenCount = (0..<(frame.width * frame.height)).filter { pixels[$0 * 4] < 100 && pixels[$0 * 4 + 1] > 160 && pixels[$0 * 4 + 2] < 100 }.count
        XCTAssertGreaterThan(greenCount, 100, "書出し動画に緑の縁取りを保持")
        let magentaPixels = (0..<(frame.width * frame.height)).filter {
            pixels[$0 * 4] > 140 && pixels[$0 * 4 + 1] < 70 && pixels[$0 * 4 + 2] > 140
        }
        XCTAssertGreaterThan(magentaPixels.count, 500, "書出し動画に設定した折れ線の色を保持")
        let spectrumColumns = magentaPixels.map { $0 % frame.width }
        XCTAssertEqual(try XCTUnwrap(spectrumColumns.min()), layout.x, accuracy: 16)
        XCTAssertEqual(try XCTUnwrap(spectrumColumns.max()), layout.x + layout.width, accuracy: 16)
        for (time, expectsBlue) in [(0.2, false), (0.6, true), (0.733, false), (0.9, false)] {
            let sample = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 30), actualTime: nil)
            decoded.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            let index = (900 * sample.width + 960) * 4
            XCTAssertEqual(pixels[index + 2] > pixels[index], expectsBlue, "上段画像の表示区間 \(time)秒")
        }
        for (videoFrame, expectsZoom) in [(9, false), (10, true)] {
            let sample = try generator.copyCGImage(at: CMTime(value: Int64(videoFrame), timescale: 30), actualTime: nil)
            decoded.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            let edge = (540 * sample.width + 400) * 4
            XCTAssertEqual(pixels[edge] > 80, expectsZoom, "打音の直前と直後で画像の横幅が変わる")
        }
        let emptyOutput = directory.appendingPathComponent("background-only.mp4")
        try await VideoExporter.export(projectURL: projectURL, audioURL: url, features: features, settings: SceneSettings(spectrum: false), lyrics: lyrics, destination: emptyOutput, cancellation: ExportCancellation(), progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyOutput.path))
        let token = ExportCancellation(); token.cancel()
        XCTAssertThrowsError(try token.check())
    }

    func testSilence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let features = try AudioAnalyzer.analyze(url: url)
        XCTAssertTrue(features.frames.flatMap { $0 }.allSatisfy { $0 == 0 })
        XCTAssertTrue(features.transientTimes.isEmpty)
        XCTAssertEqual(features.transientPulse(at: 0.05), 0)
    }
}
