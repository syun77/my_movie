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
        let layout = SpectrumLayout(x: -20, y: 150, width: 900, height: 210, barGap: 46)
        let style = SpectrumStyle(shape: .line, color: RGBColor(red: 1, green: 0, blue: 0), resolution: .minimal, layout: layout)
        let settings = SceneSettings(bpm: 143, beatOffset: 0.75, spectrum: false, spectrumStyle: style)
        var images = ImageTrack()
        let imageID = images.register(url: image, projectURL: url)
        var clip = ImageClip(assetID: imageID, start: 0, end: 1, automaticAnimation: .beat, pulseAmount: 0.2)
        _ = clip.setKey(.rotation, at: 0, value: 0)
        _ = clip.setKey(.rotation, at: 1, value: 360)
        var curve = try XCTUnwrap(clip.curve(.rotation))
        curve.maximum = 540
        clip.setCurve(curve)
        clip.fixedValues[.x] = 120
        clip.setBaseValue(45, for: .rotation)
        images.layers[0].clips = [clip]
        try storage.save(ProjectFile(audioURL: audio, images: images, settings: settings, projectURL: url), to: url)
        let restarted = ProjectStorage(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restarted.lastProjectURL, url)
        let loaded = try restarted.read(from: url)
        XCTAssertEqual(loaded.audio.resolve(projectURL: url), audio)
        XCTAssertEqual(loaded.images.assets.first?.reference.resolve(projectURL: url), image)
        XCTAssertEqual(loaded.images.clips, [clip])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"automaticAnimation\""))
        XCTAssertEqual(loaded.settings, settings)
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
        invalid = settings; invalid.spectrumStyle.color.blue = 2
        XCTAssertThrowsError(try storage.save(ProjectFile(audioURL: audio, settings: invalid, projectURL: url), to: url))
        XCTAssertEqual(try Data(contentsOf: url), previous)

        invalid = settings; invalid.spectrumStyle.layout.height = 0
        XCTAssertThrowsError(try storage.save(ProjectFile(audioURL: audio, settings: invalid, projectURL: url), to: url))
        XCTAssertEqual(try Data(contentsOf: url), previous)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: previous) as? [String: Any])
        var savedSettings = try XCTUnwrap(json["settings"] as? [String: Any])
        var savedStyle = try XCTUnwrap(savedSettings["spectrumStyle"] as? [String: Any])
        savedStyle.removeValue(forKey: "layout")
        savedSettings["spectrumStyle"] = savedStyle
        json["settings"] = savedSettings
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try storage.read(from: url).settings.spectrumStyle, SpectrumStyle())

        savedSettings.removeValue(forKey: "spectrumStyle")
        savedSettings["spectrum"] = false
        json["settings"] = savedSettings
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let defaulted = try storage.read(from: url).settings
        XCTAssertFalse(defaulted.spectrum)
        XCTAssertEqual(defaulted.spectrumStyle, SpectrumStyle())

        let missing = directory.appendingPathComponent("missing/project.mvproject")
        XCTAssertThrowsError(try storage.save(loaded, to: missing))
        XCTAssertEqual(storage.lastProjectURL, url)
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try storage.read(from: url))
    }
}
