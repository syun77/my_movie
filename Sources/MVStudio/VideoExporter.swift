import AppKit
import AVFoundation
import Metal

final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

enum VideoExporter {
    static let width = 1920
    static let height = 1080
    static let fps: Int32 = 30
    static let averageBitRate = 12_000_000

    static func export(images: ImageTrack = ImageTrack(), projectURL: URL, audioURL: URL, features: AudioFeatures, settings: SceneSettings, lyrics: LyricsTrack = LyricsTrack(), destination: URL, cancellation: ExportCancellation, progress: @escaping (Double) -> Void) async throws {
        try cancellation.check()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let finalURL = temporary.appendingPathComponent("final.mp4")
        let imageStore = ImageAssetStore()
        try await imageStore.validateUsed(track: images, projectURL: projectURL)
        try cancellation.check()
        try await Task.detached {
            try await renderVideo(images: images, projectURL: projectURL, imageStore: imageStore, audioURL: audioURL,
                                  features: features, settings: settings, lyrics: lyrics, url: finalURL,
                                  cancellation: cancellation, progress: progress)
        }.value
        try cancellation.check()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: finalURL)
        } else {
            try FileManager.default.copyItem(at: finalURL, to: destination)
        }
        progress(1)
    }

    private final class AudioSamples {
        let input: AVAssetWriterInput
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private var next: CMSampleBuffer?
        private(set) var finished = false

        init(asset: AVAsset, track: AVAssetTrack, format: AudioStreamBasicDescription) throws {
            reader = try AVAssetReader(asset: asset)
            let channels = min(2, Int(format.mChannelsPerFrame))
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw StudioError.message("音声トラックを読み込めません。") }
            reader.add(output)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(48_000, format.mSampleRate),
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000
            ])
            guard reader.startReading() else { throw reader.error ?? StudioError.message("音声の読込を開始できません。") }
        }

        func appendAvailable(through time: Double, writer: AVAssetWriter, cancellation: ExportCancellation) throws {
            while !finished, input.isReadyForMoreMediaData {
                try cancellation.check()
                if next == nil { next = output.copyNextSampleBuffer() }
                guard let sample = next else {
                    guard reader.status == .completed else { throw reader.error ?? StudioError.message("音声の読込が停止しました。") }
                    input.markAsFinished()
                    finished = true
                    return
                }
                guard sample.numSamples > 0 else { next = nil; continue }
                guard sample.presentationTimeStamp.seconds <= time else { return }
                guard input.append(sample) else { throw writer.error ?? StudioError.message("音声を書き込めません。") }
                next = nil
            }
        }

        deinit { reader.cancelReading() }
    }

    private static func renderVideo(images: ImageTrack, projectURL: URL, imageStore: ImageAssetStore, audioURL: URL, features: AudioFeatures, settings: SceneSettings, lyrics: LyricsTrack, url: URL, cancellation: ExportCancellation, progress: (Double) -> Void) async throws {
        let renderer = try MetalSceneRenderer()
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else { throw MetalSceneRenderer.renderError }
        let asset = AVURLAsset(url: audioURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw StudioError.message("音声トラックの形式を取得できません。")
        }
        let audio = try AudioSamples(asset: asset, track: track, format: format)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: averageBitRate, AVVideoAllowFrameReorderingKey: false]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw StudioError.message("H.264出力を利用できません。") }
        writer.add(input)
        guard writer.canAdd(audio.input) else { throw StudioError.message("AAC出力を利用できません。") }
        writer.add(audio.input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("書き出しを開始できません。") }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { writer.cancelWriting() } }
        let total = Int(ceil(features.duration * Double(fps)))
        for index in 0..<total {
            try cancellation.check()
            let time = Double(index) / Double(fps)
            try audio.appendAvailable(through: time + 0.1, writer: writer, cancellation: cancellation)
            while !input.isReadyForMoreMediaData {
                try cancellation.check()
                guard writer.status == .writing else { throw writer.error ?? StudioError.message("エンコードが停止しました。") }
                try audio.appendAvailable(through: .infinity, writer: writer, cancellation: cancellation)
                try await Task.sleep(for: .milliseconds(2))
            }
            let layers = try await imageStore.layers(track: images, projectURL: projectURL, time: time, allowMissing: false)
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                    throw StudioError.message("動画フレームを確保できません。")
                }
                CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                var wrapped: CVMetalTexture?
                let attributes = [kCVMetalTextureUsage: MTLTextureUsage.renderTarget.rawValue] as CFDictionary
                guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixel, attributes, .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
                      let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { throw MetalSceneRenderer.renderError }
                let commands = try renderer.encode(images: layers, features: features, settings: settings, lyrics: lyrics,
                                                   time: time, target: texture, video: true)
                commands.commit()
                withExtendedLifetime(wrapped) { commands.waitUntilCompleted() }
                guard commands.status == .completed else { throw commands.error ?? MetalSceneRenderer.renderError }
                try cancellation.check()
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                    throw writer.error ?? StudioError.message("フレームの書き込みに失敗しました。")
                }
            }
            if index % 15 == 0 { progress(Double(index) / Double(total) * 0.99) }
        }
        input.markAsFinished()
        while !audio.finished {
            try cancellation.check()
            guard writer.status == .writing else { throw writer.error ?? StudioError.message("エンコードが停止しました。") }
            try audio.appendAvailable(through: .infinity, writer: writer, cancellation: cancellation)
            if !audio.finished { try await Task.sleep(for: .milliseconds(2)) }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(total), timescale: fps))
        await writer.finishWriting()
        try cancellation.check()
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("動画を確定できません。") }
        finished = true
    }
}
