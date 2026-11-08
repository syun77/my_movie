import AppKit
import AVFoundation

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
    static func export(image: CGImage, audioURL: URL, features: AudioFeatures, settings: SceneSettings, destination: URL, cancellation: ExportCancellation, progress: @escaping (Double) -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let silentURL = temporary.appendingPathComponent("silent.mp4")
        let finalURL = temporary.appendingPathComponent("final.mp4")
        try await Task.detached {
            try renderVideo(image: image, features: features, settings: settings, url: silentURL, cancellation: cancellation, progress: progress)
        }.value
        try cancellation.check()
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silentURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.message("映像または音声トラックを作成できません。")
        }
        let duration = CMTime(seconds: features.duration, preferredTimescale: 48000)
        let range = CMTimeRange(start: .zero, duration: duration)
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StudioError.message("動画の結合を開始できません。")
        }
        session.outputURL = finalURL
        session.outputFileType = .mp4
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        let monitor = Task {
            while !Task.isCancelled {
                do { try cancellation.check() } catch { session.cancelExport(); return }
                progress(0.85 + Double(session.progress) * 0.14)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await session.export()
        monitor.cancel()
        try cancellation.check()
        guard session.status == .completed else { throw session.error ?? StudioError.message("動画の結合に失敗しました。") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: finalURL)
        } else {
            try FileManager.default.copyItem(at: finalURL, to: destination)
        }
        progress(1)
    }

    private static func renderVideo(image: CGImage, features: AudioFeatures, settings: SceneSettings, url: URL, cancellation: ExportCancellation, progress: (Double) -> Void) throws {
        let width = 1280, height = 720, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw StudioError.message("H.264出力を利用できません。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("書き出しを開始できません。") }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { writer.cancelWriting() } }
        let total = Int(ceil(features.duration * Double(fps)))
        for index in 0..<total {
            try cancellation.check()
            while !input.isReadyForMoreMediaData {
                try cancellation.check()
                guard writer.status == .writing else { throw writer.error ?? StudioError.message("エンコードが停止しました。") }
                Thread.sleep(forTimeInterval: 0.002)
            }
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                    throw StudioError.message("動画フレームを確保できません。")
                }
                CVPixelBufferLockBaseAddress(pixel, [])
                defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                    throw StudioError.message("描画領域を作成できません。")
                }
                SceneRenderer.draw(in: context, size: CGSize(width: width, height: height), image: image, features: features, settings: settings, time: Double(index) / Double(fps))
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                    throw writer.error ?? StudioError.message("フレームの書き込みに失敗しました。")
                }
            }
            if index % 15 == 0 { progress(Double(index) / Double(total) * 0.85) }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: features.duration, preferredTimescale: 48000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut { try cancellation.check() }
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("動画を確定できません。") }
        finished = true
    }
}
