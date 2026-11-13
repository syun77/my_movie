import Foundation

struct ProjectFile: Codable {
    static let currentVersion = 8

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

    mutating func upgradeVersion() { version = Self.currentVersion }

    func validate() throws {
        guard version == Self.currentVersion else { throw StudioError.message("このプロジェクトの形式には対応していません。") }
        try lyrics.validate()
        try visuals.validate()
        let imageClips = visuals.clips
        let keyIDs = imageClips.flatMap { clip in clip.curves.flatMap { $0.keys.map(\.id) } }
        let ids = visualAssets.map(\.id) + visualLayers.map(\.id) + imageClips.map(\.id) + keyIDs + lyrics.clips.map(\.id)
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

struct ProjectStorage {
    private let defaults: UserDefaults
    private let lastProjectKey = "lastProjectURL"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastProjectURL: URL? {
        defaults.string(forKey: lastProjectKey).map { URL(fileURLWithPath: $0) }
    }

    static func projectURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("mvproject")
    }

    func read(from url: URL) throws -> ProjectFile {
        let project = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
        try project.validate()
        return project
    }

    func save(_ project: ProjectFile, to url: URL) throws {
        try project.validate()
        var updated = project
        updated.upgradeVersion()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: url, options: .atomic)
        remember(url)
    }

    private func remember(_ url: URL) { defaults.set(url.path, forKey: lastProjectKey) }
}
