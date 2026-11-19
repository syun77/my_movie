import Foundation

struct ProjectStorage {
    struct FileAccess {
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
        var backup: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .withoutOverwriting) }
        var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    }
    private let files: FileAccess
    private let defaults: UserDefaults
    private let lastProjectKey = "lastProjectURL"

    init(defaults: UserDefaults = .standard, files: FileAccess = FileAccess()) {
        self.defaults = defaults
        self.files = files
    }

    var lastProjectURL: URL? {
        defaults.string(forKey: lastProjectKey).map { URL(fileURLWithPath: $0) }
    }

    static func projectURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("mvproject")
    }

    func read(from url: URL) throws -> ProjectFile {
        try readForOpening(from: url).project
    }

    func readForOpening(from url: URL) throws -> ProjectReadResult {
        try ProjectMigrator.read(files.read(url), at: url)
    }

    /// 音声解析・区間検証の成功後、編集状態の切替より前に呼ぶ。
    @discardableResult
    func commitMigration(_ result: ProjectReadResult) throws -> URL? {
        guard result.needsMigration else { return nil }
        let data = try encoded(result.project)
        var coordinationError: NSError?
        var outcome: Result<URL, Error>?
        NSFileCoordinator().coordinate(writingItemAt: result.sourceURL, options: .forReplacing, error: &coordinationError) { url in
            outcome = Result {
                guard try files.read(url) == result.originalData else { throw ProjectFormatError.changed }
                let backup = url.appendingPathExtension("v\(result.sourceVersion).\(UUID().uuidString).backup")
                try files.backup(result.originalData, backup)
                guard try files.read(url) == result.originalData else { throw ProjectFormatError.changed }
                try files.write(data, url)
                return backup
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw ProjectFormatError.invalid("ファイルの書き込み調整") }
        let backup = try outcome.get()
        remember(result.sourceURL)
        return backup
    }

    func save(_ project: ProjectFile, to url: URL) throws {
        try files.write(encoded(project), url)
        remember(url)
    }

    private func encoded(_ project: ProjectFile) throws -> Data {
        try project.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    private func remember(_ url: URL) { defaults.set(url.path, forKey: lastProjectKey) }
}
