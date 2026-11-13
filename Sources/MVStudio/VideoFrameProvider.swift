import AVFoundation
import CoreImage

struct VideoMetadata: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let range: CMTimeRange
    let transform: CGAffineTransform

    static func load(_ url: URL) async throws -> VideoMetadata {
        guard url.isFileURL else { throw StudioError.message("ローカルの動画ファイルを指定してください。") }
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError.message("再生可能な映像トラックがありません。")
        }
        let range = try await track.load(.timeRange)
        let transform = try await track.load(.preferredTransform)
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
            if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || (extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool) == true {
                throw StudioError.message("HDR・透過動画は現在対応していません。SDR動画を使用してください。")
            }
        }
        guard range.start.isNumeric, range.duration.isNumeric, range.duration.seconds >= 1.0 / 30 else {
            throw StudioError.message("動画の有効な長さを確認できません。")
        }
        return VideoMetadata(asset: asset, track: track, range: range, transform: transform)
    }
}

/// Each session is owned exclusively by the provider actor.
private final class VideoSession {
    let url: URL
    let metadata: VideoMetadata
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var currentFrame: VisualFrame?
    private var lastRequested = -Double.infinity

    init(url: URL, metadata: VideoMetadata) { self.url = url; self.metadata = metadata }
    deinit { reader?.cancelReading() }

    private func restart(at localTime: Double) throws {
        reader?.cancelReading()
        let reader = try AVAssetReader(asset: metadata.asset)
        let output = AVAssetReaderTrackOutput(track: metadata.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioError.message("動画のデコードを構成できません。") }
        reader.add(output)
        let start = CMTimeAdd(metadata.range.start, CMTime(seconds: max(0, localTime - 1), preferredTimescale: 600_000))
        reader.timeRange = CMTimeRange(start: start, end: metadata.range.end)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("動画を読み込めません。") }
        self.reader = reader; self.output = output
        current = nil; next = nil; currentFrame = nil
    }

    func frame(at localTime: Double, cancellation: ExportCancellation? = nil) throws -> VisualFrame {
        try Task.checkCancellation(); try cancellation?.check()
        guard localTime.isFinite, localTime >= 0, localTime < metadata.range.duration.seconds + 1e-9 else {
            throw StudioError.message("動画の参照位置が素材範囲外です。")
        }
        if reader == nil || localTime < lastRequested || localTime - lastRequested > 1 { try restart(at: localTime) }
        lastRequested = localTime
        let target = metadata.range.start.seconds + localTime
        if current == nil {
            current = try read()
            if current.map({ $0.presentationTimeStamp.seconds > target + 1e-6 }) ?? true, localTime > 0 {
                try restart(at: 0); current = try read()
            }
        }
        if next == nil { next = try read() }
        while let sample = next, sample.presentationTimeStamp.seconds <= target + 1e-9 {
            try Task.checkCancellation(); try cancellation?.check()
            current = sample; currentFrame = nil; next = try read()
        }
        guard let current, current.presentationTimeStamp.seconds <= target + 1e-6,
              let buffer = CMSampleBufferGetImageBuffer(current) else {
            throw StudioError.message("指定時刻の映像フレームがありません。")
        }
        if let currentFrame { return currentFrame }
        let frame = VisualFrame(buffer: buffer, transform: metadata.transform, presentationTime: current.presentationTimeStamp)
        currentFrame = frame
        return frame
    }

    var bufferCost: Int {
        [current, next].compactMap { $0 }.compactMap { CMSampleBufferGetImageBuffer($0) }
            .reduce(0) { $0 + CVPixelBufferGetDataSize($1) }
    }

    private func read() throws -> CMSampleBuffer? {
        let sample = output?.copyNextSampleBuffer()
        if sample == nil, let reader, reader.status != .completed {
            throw reader.error ?? StudioError.message("動画の読込が停止しました。")
        }
        return sample
    }
}

actor VideoFrameProvider {
    private var sessions: [UUID: VideoSession] = [:]

    func invalidate() { sessions.removeAll() }

    func inspect(_ url: URL) async throws -> (VisualAssetKind, CGImage) {
        let metadata = try await VideoMetadata.load(url)
        let session = VideoSession(url: url, metadata: metadata)
        let frame = try session.frame(at: 0)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let scale = min(1, 320 / max(frame.image.extent.width, frame.image.extent.height))
        let small = frame.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let thumbnail = context.createCGImage(small, from: small.extent) else {
            throw StudioError.message("動画の代表画像を取得できません。")
        }
        return (.video(duration: metadata.range.duration.seconds), thumbnail)
    }

    func layers(track: VisualTrack, projectURL: URL, time: Double, cancellation: ExportCancellation? = nil) async throws -> [VisualRenderLayer] {
        let active = track.active(at: time).filter { $0.content.sourceIn != nil }
        let ids = Set(active.map(\.id))
        sessions = sessions.filter { ids.contains($0.key) }
        var result: [VisualRenderLayer] = []
        for clip in active {
            try Task.checkCancellation(); try cancellation?.check()
            guard let asset = track.asset(clip.assetID), clip.content.sourceIn != nil else { continue }
            let url = asset.reference.resolve(projectURL: projectURL)
            let session: VideoSession
            if let existing = sessions[clip.id], existing.url == url { session = existing }
            else {
                session = VideoSession(url: url, metadata: try await VideoMetadata.load(url))
                sessions[clip.id] = session
            }
            guard clip.sourceEnd <= session.metadata.range.duration.seconds + 1e-9 else {
                throw StudioError.message("動画が短くなっています。素材管理で置き換えてください。")
            }
            result.append(VisualRenderLayer(clip: clip, frame: try session.frame(at: clip.sourceTime(at: time), cancellation: cancellation)))
            guard sessions.values.reduce(0, { $0 + $1.bufferCost }) <= 128 * 1024 * 1024 else {
                sessions.removeAll()
                throw StudioError.message("動画フレームが128MiBの上限を超えています。動画の解像度または同時配置数を減らしてください。")
            }
        }
        return result
    }
}
