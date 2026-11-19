import Foundation

/// Only still sources can be rebound without evaluating their source clock again.
enum PreviewFrameReuse {
    static func stills(_ layers: [VisualRenderLayer], track: VisualTrack, time: Double) -> [VisualRenderLayer]? {
        var result: [VisualRenderLayer] = []
        for clip in track.active(at: time) {
            guard clip.content == .still,
                  let layer = layers.first(where: { $0.clip.id == clip.id && $0.clip.assetID == clip.assetID && $0.clip.content == .still }),
                  let frame = layer.frame else { return nil }
            var updated = VisualRenderLayer(clip: clip, frame: frame)
            guard layer.clip.activeParticleAssetIDs == clip.activeParticleAssetIDs else { return nil }
            updated.particleImages = layer.particleImages
            updated.updatePlacement(from: track)
            result.append(updated)
        }
        return result
    }
}
