import XCTest
@testable import MVStudio

final class ProjectStorageTests: XCTestCase {
    func testSaveRestoreAndRelocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MVStudioTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectStorage(defaults: defaults)
        XCTAssertNil(storage.lastProjectURL)
        let audio = directory.appendingPathComponent("曲.wav")
        let image = directory.appendingPathComponent("背景.png")
        let url = ProjectStorage.projectURL(for: audio)
        XCTAssertEqual(url.lastPathComponent, "曲.wav.mvproject")
        XCTAssertNotEqual(url, ProjectStorage.projectURL(for: directory.appendingPathComponent("曲.mp3")))
        let settings = SceneSettings(bpm: 143, beatOffset: 0.75, spectrum: false)
        var images = ImageTrack()
        _ = images.register(url: image, projectURL: url)
        try storage.save(ProjectFile(audioURL: audio, images: images, settings: settings, projectURL: url), to: url)
        let restarted = ProjectStorage(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restarted.lastProjectURL, url)
        let loaded = try restarted.read(from: url)
        XCTAssertEqual(loaded.audio.resolve(projectURL: url), audio)
        XCTAssertEqual(loaded.images.assets.first?.reference.resolve(projectURL: url), image)
        XCTAssertEqual(loaded.settings.bpm, 143)
        XCTAssertEqual(loaded.settings.beatOffset, 0.75)
        XCTAssertFalse(loaded.settings.spectrum)
        let moved = directory.appendingPathComponent("moved/曲.wav.mvproject")
        XCTAssertEqual(loaded.audio.resolve(projectURL: moved), moved.deletingLastPathComponent().appendingPathComponent("曲.wav"))
        let outside = URL(fileURLWithPath: "/tmp/external/image.png")
        XCTAssertEqual(AssetReference(url: outside, projectURL: url).resolve(projectURL: moved), outside)
        try storage.save(ProjectFile(audioURL: audio, settings: SceneSettings(), projectURL: url), to: url)
        XCTAssertTrue(try storage.read(from: url).images.assets.isEmpty)
        let previous = try Data(contentsOf: url)
        var invalid = settings; invalid.bpm = .nan
        XCTAssertThrowsError(try storage.save(ProjectFile(audioURL: audio, settings: invalid, projectURL: url), to: url))
        XCTAssertEqual(try Data(contentsOf: url), previous)
        let missing = directory.appendingPathComponent("missing/project.mvproject")
        XCTAssertThrowsError(try storage.save(loaded, to: missing))
        XCTAssertEqual(storage.lastProjectURL, url)
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try storage.read(from: url))
    }
}
