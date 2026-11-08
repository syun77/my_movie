import Foundation

struct ProjectFile: Codable {
    let version: Int
    let audio: AssetReference
    let image: AssetReference?
    let settings: SceneSettings

    init(audioURL: URL, imageURL: URL?, settings: SceneSettings, projectURL: URL) {
        version = 1
        audio = AssetReference(url: audioURL, projectURL: projectURL)
        image = imageURL.map { AssetReference(url: $0, projectURL: projectURL) }
        self.settings = settings
    }

    func validate() throws {
        guard version == 1 else { throw StudioError.message("このプロジェクトの形式には対応していません。") }
        guard settings.bpm.isFinite, (20...300).contains(settings.bpm),
              settings.beatOffset.isFinite, settings.beatOffset >= 0,
              settings.pulse.isFinite, (0...0.25).contains(settings.pulse) else {
            throw StudioError.message("プロジェクトの設定値が不正です。")
        }
    }
}

struct AssetReference: Codable {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url, options: .atomic)
        remember(url)
    }

    private func remember(_ url: URL) { defaults.set(url.path, forKey: lastProjectKey) }
}
