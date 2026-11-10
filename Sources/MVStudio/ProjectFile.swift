import Foundation

struct ProjectFile: Codable {
    static let currentVersion = 5

    private(set) var version: Int
    let audio: AssetReference
    let imageAssets: [ImageAsset]
    let imageLayers: [ImageLayer]
    var images: ImageTrack { ImageTrack(assets: imageAssets, layers: imageLayers) }
    let settings: SceneSettings
    let lyrics: LyricsTrack

    init(audioURL: URL, images: ImageTrack = ImageTrack(), settings: SceneSettings, lyrics: LyricsTrack = LyricsTrack(), projectURL: URL) {
        version = Self.currentVersion
        audio = AssetReference(url: audioURL, projectURL: projectURL)
        imageAssets = images.assets
        imageLayers = images.layers
        self.settings = settings
        self.lyrics = lyrics
    }

    mutating func upgradeVersion() { version = Self.currentVersion }

    func validate() throws {
        guard version == Self.currentVersion || (version == 4 && images.clips.allSatisfy { $0.effects == nil }) else { throw StudioError.message("このプロジェクトの形式には対応していません。") }
        try lyrics.validate()
        try images.validate()
        let imageClips = images.clips
        let keyIDs = imageClips.flatMap { clip in clip.curves.flatMap { $0.keys.map(\.id) } }
        let ids = imageAssets.map(\.id) + imageLayers.map(\.id) + imageClips.map(\.id) + keyIDs + lyrics.clips.map(\.id)
        guard Set(ids).count == ids.count else { throw StudioError.message("プロジェクト内のIDが重複しています。") }
        guard settings.bpm.isFinite, (20...300).contains(settings.bpm),
              settings.beatOffset.isFinite, settings.beatOffset >= 0, settings.spectrumStyle.isValid else {
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
