import XCTest
import AVFoundation
@testable import MVStudio

final class StudioTests: XCTestCase {
    func testBeatOffsetAndDeterministicEvaluation() {
        let settings = SceneSettings(bpm: 120, beatOffset: 1, pulse: 0.1)
        XCTAssertEqual(settings.scale(at: 0.9), 1)
        XCTAssertEqual(settings.scale(at: 1), 1.1, accuracy: 0.0001)
        XCTAssertEqual(settings.scale(at: 1.5), 1.1, accuracy: 0.0001)
        XCTAssertLessThan(settings.scale(at: 1.4), 1.01)
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
        try await VideoExporter.export(image: context.makeImage()!, audioURL: url, features: features, settings: SceneSettings(), destination: output, cancellation: ExportCancellation(), progress: { _ in })
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 1.0 / 30)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        XCTAssertEqual(frame.width, 1280); XCTAssertEqual(frame.height, 720)
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
