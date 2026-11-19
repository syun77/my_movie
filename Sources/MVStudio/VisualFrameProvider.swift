import Foundation

/// Preview and export own separate instances so their decoding positions never interfere.
actor VisualFrameProvider {
    private let stills = ImageAssetStore()
    private let spines = SpinePoseProvider()
    private let videos = VideoFrameProvider()
    private var pinnedParticles: [UUID: VisualFrame] = [:]

    func invalidate() async { pinnedParticles = [:]; await stills.invalidate(); await videos.invalidate(); await spines.invalidate() }

    func validateUsed(track: VisualTrack, projectURL: URL, cancellation: ExportCancellation) async throws {
        try cancellation.check()
        pinnedParticles = [:]
        try await VisualAssetLoader().validateUsed(track: track, projectURL: projectURL, cancellation: cancellation, includeSpine: false)
        var prepared: [UUID: VisualFrame] = [:]
        var cost = 0
        for id in Set(track.visibleClips.flatMap { $0.activeParticleAssetIDs }) {
            try Task.checkCancellation(); try cancellation.check()
            guard let asset = track.asset(id) else { throw StudioError.message("粒子画像が見つかりません。") }
            let image = try await stills.image(at: asset.reference.resolve(projectURL: projectURL), maximumSize: 2048)
            cost += image.bytesPerRow * image.height
            guard cost <= 128 * 1024 * 1024 else { throw StudioError.message("粒子画像がメモリ上限128MiBを超えています。画像数を減らしてください。") }
            prepared[id] = VisualFrame(image)
        }
        try await spines.prepare(track: track, projectURL: projectURL, cancellation: cancellation)
        pinnedParticles = prepared
    }

    func layers(track: VisualTrack, projectURL: URL, time: Double, allowMissingImages: Bool,
                cancellation: ExportCancellation? = nil) async throws -> [VisualRenderLayer] {
        try Task.checkCancellation(); try cancellation?.check()
        let images = try await stills.layers(track: track, projectURL: projectURL, time: time, allowMissing: allowMissingImages)
        let movies = try await videos.layers(track: track, projectURL: projectURL, time: time, cancellation: cancellation)
        try Task.checkCancellation(); try cancellation?.check()
        let spine = try await spines.layers(track: track, projectURL: projectURL, time: time, cancellation: cancellation)
        var particleImages = pinnedParticles
        for id in Set(track.active(at: time).flatMap { $0.activeParticleAssetIDs }) where particleImages[id] == nil {
            try Task.checkCancellation(); try cancellation?.check()
            guard let asset = track.asset(id) else { throw StudioError.message("粒子画像の参照が不正です。") }
            do { particleImages[id] = VisualFrame(try await stills.image(at: asset.reference.resolve(projectURL: projectURL), maximumSize: 2048)) }
            catch { if !allowMissingImages { throw StudioError.message("粒子画像を確認してください: " + asset.name) } }
        }
        return (images + movies + spine).map { layer in
            var result = layer
            result.particleImages = particleImages.filter { layer.clip.activeParticleAssetIDs.contains($0.key) }
            result.updatePlacement(from: track)
            return result
        }.sorted { $0.order < $1.order }
    }
}
