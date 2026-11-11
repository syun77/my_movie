import AppKit

actor VisualAssetLoader {
    private let stills = ImageAssetStore()
    private let videos = VideoFrameProvider()

    func inspect(_ url: URL, maximumSize: Int = 2400) async throws -> (kind: VisualAssetKind, thumbnail: CGImage) {
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let result = try await videos.inspect(url)
            return (result.0, result.1)
        }
        return (.still, try await stills.image(at: url, maximumSize: maximumSize))
    }

    func validateUsed(track: VisualTrack, projectURL: URL, cancellation: ExportCancellation? = nil) async throws {
        for id in Set(track.clips.map(\.assetID)) {
            try Task.checkCancellation(); try cancellation?.check()
            guard let asset = track.asset(id) else { throw StudioError.message("素材が見つかりません。") }
            let info: (kind: VisualAssetKind, thumbnail: CGImage)
            do { info = try await inspect(asset.reference.resolve(projectURL: projectURL)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw StudioError.message("素材を確認してください: \(asset.name)（素材管理から置き換え可能）\n" + error.localizedDescription) }
            try Task.checkCancellation(); try cancellation?.check()
            guard (info.kind.videoDuration != nil) == (asset.kind.videoDuration != nil),
                  track.uses(id).allSatisfy({ clip in
                      guard let sourceIn = clip.content.sourceIn, let length = info.kind.videoDuration else { return true }
                      return sourceIn + clip.end - clip.start <= length + 1e-9
                  }) else { throw StudioError.message("動画の参照区間を確認してください。") }
        }
    }

    func invalidate() async { await stills.invalidate(); await videos.invalidate() }
}
