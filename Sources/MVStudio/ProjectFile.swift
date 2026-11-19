import Foundation

struct ProjectFile: Codable {
    static let currentVersion = 15
    static let oldestSupportedVersion = currentVersion - 3

    private(set) var version: Int
    let audio: AssetReference
    let visualAssets: [VisualAsset]
    let visualLayers: [VisualLayer]
    var visuals: VisualTrack { VisualTrack(assets: visualAssets, layers: visualLayers) }
    let settings: SceneSettings
    let lyrics: LyricsTrack
    let timelineHeights: TimelineHeights?

    init(audioURL: URL, visuals: VisualTrack = VisualTrack(), settings: SceneSettings, lyrics: LyricsTrack = LyricsTrack(), timelineHeights: TimelineHeights? = nil, projectURL: URL) {
        version = Self.currentVersion
        audio = AssetReference(url: audioURL, projectURL: projectURL)
        visualAssets = visuals.assets
        visualLayers = visuals.layers
        self.settings = settings
        self.lyrics = lyrics
        self.timelineHeights = timelineHeights
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw StudioError.message("このプロジェクトの形式には対応していません。") }
        try lyrics.validate()
        try visuals.validate()
        let imageClips = visuals.clips
        let keyIDs = imageClips.flatMap { clip in clip.curves.flatMap { $0.keys.map(\.id) } }
        let spineIDs = imageClips.flatMap { $0.content.spinePlayback?.keyIDs ?? [] }
        let nodeIDs = imageClips.flatMap { $0.effects?.allNodes.map(\.id) ?? [] }
        let ids = nodeIDs + spineIDs + visualAssets.map(\.id) + visualLayers.map(\.id) + imageClips.map(\.id) + keyIDs + lyrics.clips.map(\.id)
        guard Set(ids).count == ids.count else { throw StudioError.message("プロジェクト内のIDが重複しています。") }
        guard settings.bpm.isFinite, (20...300).contains(settings.bpm),
              settings.beatOffset.isFinite, settings.beatOffset >= 0, settings.spectrumStyle.isValid,
              timelineHeights?.isValid != false else {
            throw StudioError.message("プロジェクトの設定値が不正です。")
        }
    }
}

struct AssetReference: Codable, Sendable, Equatable {
    let path: String
    let relative: Bool

    init(url: URL, projectURL: URL) {
        relative = url.deletingLastPathComponent().standardizedFileURL == projectURL.deletingLastPathComponent().standardizedFileURL
        path = relative ? url.lastPathComponent : url.path
    }

    func resolve(projectURL: URL) -> URL {
        relative ? projectURL.deletingLastPathComponent().appendingPathComponent(path) : URL(fileURLWithPath: path)
    }
}
