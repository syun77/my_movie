import Foundation

/// Preview and export own separate instances so their decoding positions never interfere.
actor VisualFrameProvider {
    private let stills = ImageAssetStore()
    private let spines = SpinePoseProvider()
    private let videos = VideoFrameProvider()

    func invalidate() async { await stills.invalidate(); await videos.invalidate(); await spines.invalidate() }

    func validateUsed(track: VisualTrack, projectURL: URL, cancellation: ExportCancellation) async throws {
        try cancellation.check()
        try await spines.prepare(track: track, projectURL: projectURL, cancellation: cancellation)
        try await VisualAssetLoader().validateUsed(track: track, projectURL: projectURL, cancellation: cancellation, includeSpine: false)
    }

    func layers(track: VisualTrack, projectURL: URL, time: Double, allowMissingImages: Bool,
                cancellation: ExportCancellation? = nil) async throws -> [VisualRenderLayer] {
        try Task.checkCancellation(); try cancellation?.check()
        let images = try await stills.layers(track: track, projectURL: projectURL, time: time, allowMissing: allowMissingImages)
        let movies = try await videos.layers(track: track, projectURL: projectURL, time: time, cancellation: cancellation)
        try Task.checkCancellation(); try cancellation?.check()
        let spine = try await spines.layers(track: track, projectURL: projectURL, time: time, cancellation: cancellation)
        return (images + movies + spine).sorted { (track.slot(of: $0.clip.id) ?? 0) < (track.slot(of: $1.clip.id) ?? 0) }
    }
}
