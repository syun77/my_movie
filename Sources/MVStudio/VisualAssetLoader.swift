import AppKit

actor VisualAssetLoader {
    private let stills = ImageAssetStore()
    private let spines = SpinePoseProvider()
    private let videos = VideoFrameProvider()

    func inspect(_ url: URL, maximumSize: Int = 2400, atlasURL: URL? = nil) async throws -> (kind: VisualAssetKind, thumbnail: CGImage) {
        if url.pathExtension.lowercased() == "json" {
            let atlas = atlasURL ?? url.deletingPathExtension().appendingPathExtension("atlas")
            let (descriptor, packet) = try await spines.inspect(skeleton: url, atlas: atlas)
            return (.spine(descriptor), try SpineMetalRenderer.thumbnail(packet, maximumSize: maximumSize))
        }
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let result = try await videos.inspect(url)
            return (result.0, result.1)
        }
        return (.still, try await stills.image(at: url, maximumSize: maximumSize))
    }

    func validateUsed(track: VisualTrack, projectURL: URL, cancellation: ExportCancellation? = nil, includeSpine: Bool = true) async throws {
        for id in Set(track.clips.compactMap(\.assetID)) {
            try Task.checkCancellation(); try cancellation?.check()
            guard let asset = track.asset(id) else { throw StudioError.message("素材が見つかりません。") }
            if !includeSpine, asset.kind.spineDescriptor != nil { continue }
            let info: (kind: VisualAssetKind, thumbnail: CGImage)
            do { info = try await inspect(asset.reference.resolve(projectURL: projectURL), atlasURL: asset.kind.spineDescriptor?.atlasReference.resolve(projectURL: projectURL)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw StudioError.message("素材を確認してください: \(asset.name)（素材管理から置き換え可能）\n" + error.localizedDescription) }
            try Task.checkCancellation(); try cancellation?.check()
            guard info.kind.sameType(as: asset.kind),
                  track.uses(id).allSatisfy({ clip in
                      guard info.kind.accepts(clip.content) else { return false }
                      guard clip.content.sourceIn != nil, let length = info.kind.videoDuration else { return true }
                      return clip.sourceEnd <= length + 1e-9
                  }) else { throw StudioError.message("動画の参照区間を確認してください。") }
        }
    }

    func invalidate() async { await stills.invalidate(); await videos.invalidate(); await spines.invalidate() }
}
