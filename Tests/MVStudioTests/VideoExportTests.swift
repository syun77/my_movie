import AVFoundation
import ImageIO
import Metal
import XCTest
@testable import MVStudio

final class VideoExportTests: XCTestCase {
    func testExportMixedLayersTrimsVFRAndOnlyMainAudio() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("main.wav")
        let duration = 2.017
        try tone(at: audio, duration: duration, frequency: 440)
        let silentMovie = directory.appendingPathComponent("frames.mov")
        try await VideoTestFixtures.makeVideo(silentMovie, codec: .h264, times: [0, 0.1, 0.35, 0.8, 1.1, 1.6, 2], end: 2.5, rotated: true)
        let movieSound = directory.appendingPathComponent("movie-sound.wav")
        try tone(at: movieSound, duration: 2.5, frequency: 1000)
        let movie = directory.appendingPathComponent("with-sound.mov")
        try await addAudio(movieSound, to: silentMovie, destination: movie)
        let movieAudio = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertEqual(movieAudio.count, 1)
        let background = directory.appendingPathComponent("blue.png")
        try blueImage(at: background)
        let project = ProjectStorage.projectURL(for: audio)
        var visuals = VisualTrack()
        let still = visuals.register(url: background, projectURL: project)
        let video = visuals.register(url: movie, projectURL: project, kind: .video(duration: 2.5))
        visuals.layers[0].clips = [VisualClip(assetID: still, start: 0, end: duration, automaticAnimation: .off)]
        var trimmed = VisualClip(assetID: video, start: 0.2, end: 1.2, content: .video(sourceIn: 0.3), automaticAnimation: .off)
        trimmed.fixedValues[.x] = 240
        visuals.layers[1].clips = [trimmed,
            VisualClip(assetID: video, start: 1.2, end: duration, content: .video(sourceIn: 1.6), automaticAnimation: .off)]
        var upper = VisualClip(assetID: video, start: 0.7, end: 1, content: .video(sourceIn: 1.1), automaticAnimation: .off)
        upper.effects = ImageEffects(blur: .init(radius: 2))
        visuals.layers[2].clips = [upper]
        // Unused missing media must not prevent export.
        _ = visuals.register(url: directory.appendingPathComponent("missing.mov"), projectURL: project, kind: .video(duration: 1))
        let features = AudioFeatures(duration: duration, step: 0.1, frames: Array(repeating: Array(repeating: 0.6, count: 64), count: 21), transientTimes: [])
        let lyrics = LyricsTrack(clips: [LyricClip(start: 0.4, end: 1.5, text: "動画と歌詞")])
        let output = directory.appendingPathComponent("result.mp4")
        try Data("previous result".utf8).write(to: output)
        var progress: [Double] = []
        try await VideoExporter.export(visuals: visuals, projectURL: project, audioURL: audio, features: features,
            settings: SceneSettings(), lyrics: lyrics, destination: output, cancellation: ExportCancellation(), progress: { progress.append($0) })
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
        let result = AVURLAsset(url: output)
        let videos = try await result.loadTracks(withMediaType: .video)
        let audios = try await result.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let size = try await videos[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let audioRange = try await audios[0].load(.timeRange)
        XCTAssertEqual(audioRange.duration.seconds, duration, accuracy: 1.0 / 8000)
        let resultDuration = try await result.load(.duration)
        XCTAssertEqual(resultDuration.seconds, 61.0 / 30, accuracy: 1e-6)
        let reader = try AVAssetReader(asset: result)
        let decoded = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let expectedFrames = VisualFrameProvider()
        let renderer = try MetalSceneRenderer()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let sampleIndices = Set([3, 6, 21, 30, 36, 60])
        var index = 0
        while let sample = decoded.copyNextSampleBuffer() {
            XCTAssertEqual(sample.presentationTimeStamp.seconds, Double(index) / 30, accuracy: 1e-6)
            if sampleIndices.contains(index) {
                let time = Double(index) / 30
                let layers = try await expectedFrames.layers(track: visuals, projectURL: project, time: time, allowMissingImages: false)
                let commands = try renderer.encode(visuals: layers, features: features, settings: SceneSettings(), lyrics: lyrics,
                    time: time, target: target, video: true)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    commands.addCompletedHandler { _ in continuation.resume() }; commands.commit()
                }
                XCTAssertEqual(commands.status, .completed)
                let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                for (x, y) in [(960, 400), (20, 20)] {
                    var expected = [UInt8](repeating: 0, count: 4)
                    target.getBytes(&expected, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                    let pixel = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                        .advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4)
                    for channel in 0..<3 { XCTAssertEqual(Int(pixel[channel]), Int(expected[channel]), accuracy: 15, "frame \(index), pixel \(x),\(y), channel \(channel)") }
                }
            }
            index += 1
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertEqual(index, 61)
        let levels = try await audioLevels(result, track: audios[0])
        XCTAssertGreaterThan(levels.main, levels.movie * 20, "Only the 440Hz project audio should be present, not the movie's 1kHz audio")
    }

    func testHEVCExportAndInvalidOrCancelledExportPreservesDestination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("clip.mov")
        try await VideoTestFixtures.makeVideo(movie, codec: .hevc, times: [0, 0.5, 1], end: 1.5)
        let audio = directory.appendingPathComponent("main.wav")
        try tone(at: audio, duration: 1, frequency: 440)
        let project = ProjectStorage.projectURL(for: audio)
        var visuals = VisualTrack()
        let id = visuals.register(url: movie, projectURL: project, kind: .video(duration: 1.5))
        visuals.layers[0].clips = [VisualClip(assetID: id, start: 0, end: 1, content: .video(sourceIn: 0), automaticAnimation: .off)]
        let output = directory.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing result".utf8)
        let features = AudioFeatures(duration: 1, step: 1, frames: [], transientTimes: [])
        try sentinel.write(to: output)
        let cancellation = ExportCancellation()
        do {
            try await VideoExporter.export(visuals: visuals, projectURL: project, audioURL: audio, features: features,
                settings: SceneSettings(spectrum: false), destination: output, cancellation: cancellation, progress: { _ in cancellation.cancel() })
            XCTFail("Expected cancellation during video export")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        let hevcOutput = directory.appendingPathComponent("hevc-source-result.mp4")
        try await VideoExporter.export(visuals: visuals, projectURL: project, audioURL: audio, features: features,
            settings: SceneSettings(spectrum: false), destination: hevcOutput, cancellation: ExportCancellation(), progress: { _ in })
        let hevcResult = AVURLAsset(url: hevcOutput)
        let hevcVideos = try await hevcResult.loadTracks(withMediaType: .video)
        XCTAssertEqual(hevcVideos.count, 1)
        let hevcDuration = try await hevcResult.load(.duration)
        XCTAssertEqual(hevcDuration.seconds, 1, accuracy: 1e-6)
        visuals.assets[0].kind = .video(duration: 3)
        visuals.layers[0].clips[0].content = .video(sourceIn: 2)
        do {
            try await VideoExporter.export(visuals: visuals, projectURL: project, audioURL: audio, features: features,
                settings: SceneSettings(), destination: output, cancellation: ExportCancellation(), progress: { _ in })
            XCTFail("Changed source duration must fail validation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("参照区間")) }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        try FileManager.default.removeItem(at: movie)
        visuals.assets[0].kind = .video(duration: 1.5)
        visuals.layers[0].clips[0].content = .video(sourceIn: 0)
        do {
            try await VideoExporter.export(visuals: visuals, projectURL: project, audioURL: audio, features: features,
                settings: SceneSettings(), destination: output, cancellation: ExportCancellation(), progress: { _ in })
            XCTFail("Missing used video must fail")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tone(at url: URL, duration: Double, frequency: Double) throws {
        let rate = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let count = AVAudioFrameCount((duration * rate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) { buffer.floatChannelData![0][index] = Float(sin(2 * .pi * frequency * Double(index) / rate) * 0.5) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func blueImage(at url: URL) throws {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func addAudio(_ audio: URL, to movie: URL, destination: URL) async throws {
        let composition = AVMutableComposition()
        let movieAsset = AVURLAsset(url: movie), audioAsset = AVURLAsset(url: audio)
        let videos = try await movieAsset.loadTracks(withMediaType: .video)
        let sounds = try await audioAsset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videos.first)
        let sound = try XCTUnwrap(sounds.first)
        let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = try await video.load(.timeRange)
        try picture.insertTimeRange(range, of: video, at: .zero)
        picture.preferredTransform = try await video.load(.preferredTransform)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: range.duration), of: sound, at: .zero)
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = destination; session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else { throw session.error ?? StudioError.message("Fixture export failed") }
    }

    private func audioLevels(_ asset: AVAsset, track: AVAssetTrack) async throws -> (main: Double, movie: Double) {
        let formats = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(formats.first)
        let rate = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee.mSampleRate
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var index = 0
        var real = [0.0, 0.0], imaginary = [0.0, 0.0]
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes), kCMBlockBufferNoErr)
            bytes.withUnsafeBytes { storage in
                for value in storage.bindMemory(to: Float.self) {
                    for (band, frequency) in [440.0, 1000.0].enumerated() {
                        let phase = 2 * Double.pi * frequency * Double(index) / rate
                        real[band] += Double(value) * cos(phase); imaginary[band] += Double(value) * sin(phase)
                    }
                    index += 1
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return (hypot(real[0], imaginary[0]), hypot(real[1], imaginary[1]))
    }
}
