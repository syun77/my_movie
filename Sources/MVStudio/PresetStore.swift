import Foundation

protocol PresetSettings: Codable {
    static var presetFilename: String { get }
    func validate() throws
}

struct NamedPreset<Settings: PresetSettings>: Codable {
    let name: String
    let settings: Settings
}

struct PresetStore<Settings: PresetSettings> {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "MV Studio/Presets", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var file: URL { directory.appending(path: Settings.presetFilename) }

    func load() throws -> [NamedPreset<Settings>] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let presets = try JSONDecoder().decode([NamedPreset<Settings>].self, from: data)
        for preset in presets { try preset.settings.validate() }
        return presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func save(name input: String, settings: Settings) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .newlines) == nil else {
            throw StudioError.message("プリセット名を1行で入力してください。")
        }
        try settings.validate()
        var presets = try load()
        guard !presets.contains(where: { $0.name == name }) else {
            throw StudioError.message("同じ名前のプリセットがあります。別の名前を入力してください。")
        }
        presets.append(NamedPreset(name: name, settings: settings))
        try write(presets)
        return name
    }

    func overwrite(name: String, settings: Settings) throws {
        try settings.validate()
        var presets = try load()
        guard let index = presets.firstIndex(where: { $0.name == name }) else {
            throw StudioError.message("上書きするプリセットが見つかりません。")
        }
        presets[index] = NamedPreset(name: name, settings: settings)
        try write(presets)
    }

    private func write(_ presets: [NamedPreset<Settings>]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(presets).write(to: file, options: .atomic)
    }
}
