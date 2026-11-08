import XCTest
import AVFoundation
import ImageIO
@testable import MVStudio

final class StudioTests: XCTestCase {
    func testBeatOffsetAndDeterministicEvaluation() {
        let settings = SceneSettings(bpm: 120, beatOffset: 1)
        let clip = ImageClip(assetID: UUID(), start: 0, end: 2, pulseAmount: 0.1)
        XCTAssertEqual(clip.scale(at: 0.9, settings: settings), 1)
        XCTAssertEqual(clip.scale(at: 1, settings: settings), 1.1, accuracy: 0.0001)
        XCTAssertEqual(clip.scale(at: 1.5, settings: settings), 1.1, accuracy: 0.0001)
        XCTAssertLessThan(clip.scale(at: 1.4, settings: settings), 1.01)
        let features = AudioFeatures(duration: 1, step: 0.5, frames: [[0, 1], [1, 0]])
        XCTAssertEqual(features.bands(at: 0.25), [0.5, 0.5])
        XCTAssertEqual(features.bands(at: 1), Array(repeating: 0, count: 32))
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
            let value = Float(sin(2 * .pi * 1000 * Double(index) / rate)) * 0.5
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = -value
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let features = try AudioAnalyzer.analyze(url: url)
        XCTAssertEqual(features.duration, 1, accuracy: 0.001)
        XCTAssertTrue(features.frames.flatMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        let middle = features.bands(at: 0.5)
        let peak = middle.indices.max(by: { middle[$0] < middle[$1] })!
        XCTAssertTrue((16...19).contains(peak), "1kHz peak: \(peak)")
        XCTAssertGreaterThan(middle[peak], 0.4, "逆相ステレオでも信号を検出")
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let output = directory.appendingPathComponent("result.mp4")
        let lyrics = LyricsTrack(clips: [LyricClip(start: 0, end: 1, text: "歌詞の縁取り")], outlineWidth: 6, outlineColor: LyricsColor(red: 0, green: 1, blue: 0))
        let imageURL = directory.appendingPathComponent("source.png")
        let imageDestination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(imageDestination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(imageDestination))
        let projectURL = ProjectStorage.projectURL(for: url)
        var images = ImageTrack()
        let assetID = images.register(url: imageURL, projectURL: projectURL)
        images.layers[0].clips = [ImageClip(assetID: assetID, start: 0, end: 1)]
        let overlayURL = directory.appendingPathComponent("overlay.png")
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let overlayDestination = CGImageDestinationCreateWithURL(overlayURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(overlayDestination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(overlayDestination))
        let overlayID = images.register(url: overlayURL, projectURL: projectURL)
        images.layers[2].clips = [ImageClip(assetID: overlayID, start: 0.5, end: 0.8, beatPulseEnabled: false)]
        try await VideoExporter.export(images: images, projectURL: projectURL, audioURL: url, features: features, settings: SceneSettings(), lyrics: lyrics, destination: output, cancellation: ExportCancellation(), progress: { _ in })
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
        for (time, expectsBlue) in [(0.2, false), (0.6, true), (0.9, false)] {
            let sample = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            decoded.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            let index = (900 * sample.width + 960) * 4
            XCTAssertEqual(pixels[index + 2] > pixels[index], expectsBlue, "上段画像の表示区間 \(time)秒")
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
        XCTAssertTrue(try AudioAnalyzer.analyze(url: url).frames.flatMap { $0 }.allSatisfy { $0 == 0 })
    }
}
