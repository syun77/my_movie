import AppKit
import AVFoundation
import XCTest
@testable import MVStudio

final class ProjectMigrationTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/song.wav.mvproject")

    private func fixture(_ version: Int) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "v\(version)", withExtension: "json", subdirectory: "Fixtures/Projects")))
    }
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func read(_ object: [String: Any]) throws -> ProjectReadResult {
        try ProjectMigrator.read(JSONSerialization.data(withJSONObject: object), at: url)
    }

    func testThreeHistoricalFixturesPreserveValuesAndEvaluation() throws {
        for version in 12...15 {
            let data = try fixture(version)
            let result = try ProjectMigrator.read(data, at: url)
            let project = result.project
            XCTAssertEqual(result.sourceVersion, version)
            XCTAssertEqual(result.needsMigration, version < ProjectFile.currentVersion)
            XCTAssertEqual(result.originalData, data)
            XCTAssertEqual(project.version, ProjectFile.currentVersion)
            XCTAssertEqual(project.settings.bpm, 143)
            XCTAssertEqual(project.settings.spectrumStyle.resolution, .medium)
            XCTAssertEqual(project.lyrics.clips.map(\.text), ["歌詞", "続き"])
            XCTAssertEqual(project.lyrics.clips[1].predecessorID, project.lyrics.clips[0].id)
            XCTAssertEqual(project.visuals.assets.map(\.reference.path), ["image.png", "video.mov", "model.json"])
            let clips = project.visuals.clips
            XCTAssertEqual(clips[0].fixedValues[.x], 120)
            XCTAssertEqual(clips[0].effects?.blur?.radius, 8)
            XCTAssertEqual(clips[0].audioModulations[.scale]?.amount, 20)
            XCTAssertEqual(clips[0].curves[0].keys.map(\.time), [-1, 2])
            XCTAssertEqual(clips[0].curves[0].value(at: 0.5), 102, accuracy: 1e-8)
            XCTAssertEqual(clips[1].sourceTime(at: 1), 4)
            XCTAssertEqual(clips[2].content.spinePlayback, SpinePlayback(animationName: "idle", sourceIn: 1.25, loop: false))
            XCTAssertEqual(project.timelineHeights?[.automation(project.visuals.layers[0].id, .rotation)], 40)
            XCTAssertEqual(project.timelineHeights?[.spine(project.visuals.layers[2].id)], version == 8 ? 80 : 100)
            let again = try ProjectMigrator.read(JSONEncoder().encode(project), at: url)
            XCTAssertFalse(again.needsMigration)
            XCTAssertEqual(again.project.visuals, project.visuals)
            XCTAssertEqual(again.project.lyrics, project.lyrics)
            XCTAssertEqual(again.project.settings, project.settings)
        }
    }

    func testNewPayloadRequiresV15AndOldVersionsDoNotAddIt() throws {
        let new = try json(fixture(15))
        XCTAssertEqual(try read(new).project.visuals.clips[0].effects?.sobelChromatic?.mode, .combined)
        var incorrectlyLabeled = new; incorrectlyLabeled["version"] = 14
        XCTAssertThrowsError(try read(incorrectlyLabeled)) { XCTAssertTrue($0.localizedDescription.contains("sobelChromatic")) }
        for version in 12...14 {
            let project = try read(json(fixture(version))).project
            XCTAssertTrue(project.visuals.clips.allSatisfy { $0.effects?.sobelChromatic == nil })
        }
    }

    func testVersionAndCorruptionErrors() throws {
        let root = try json(fixture(12))
        for (value, expected) in [(11, "対応範囲"), (16, "更新")] {
            var input = root; input["version"] = value
            XCTAssertThrowsError(try read(input)) { XCTAssertTrue($0.localizedDescription.contains(expected)) }
        }
        for value: Any in [NSNull(), true, "10", 10.5] {
            var input = root; input["version"] = value
            XCTAssertThrowsError(try read(input)) { XCTAssertTrue($0.localizedDescription.contains("version")) }
        }
        var missing = root; missing.removeValue(forKey: "version")
        XCTAssertThrowsError(try read(missing))
        XCTAssertThrowsError(try ProjectMigrator.read(Data("{".utf8), at: url)) { XCTAssertTrue($0.localizedDescription.contains("JSON")) }
    }

    func testRejectsLostFieldsInvalidEnumsDuplicateIDsAndIntervals() throws {
        var root = try json(fixture(12))
        root["unrecognizedSetting"] = ["important": 42]
        XCTAssertThrowsError(try read(root)) { XCTAssertTrue($0.localizedDescription.contains("unrecognizedSetting")) }
        root.removeValue(forKey: "unrecognizedSetting")
        var layers = try XCTUnwrap(root["visualLayers"] as? [[String: Any]])
        var clips = try XCTUnwrap(layers[0]["clips"] as? [[String: Any]])
        clips[0]["content"] = ["newKind": [:]]
        layers[0]["clips"] = clips; root["visualLayers"] = layers
        XCTAssertThrowsError(try read(root))
        root = try json(fixture(12))
        layers = try XCTUnwrap(root["visualLayers"] as? [[String: Any]])
        layers[1]["id"] = layers[0]["id"]; root["visualLayers"] = layers
        XCTAssertThrowsError(try read(root))
        root = try json(fixture(12))
        layers = try XCTUnwrap(root["visualLayers"] as? [[String: Any]])
        clips = try XCTUnwrap(layers[0]["clips"] as? [[String: Any]])
        clips[0]["end"] = -1; layers[0]["clips"] = clips; root["visualLayers"] = layers
        XCTAssertThrowsError(try read(root))
    }

    func testBackupCommitAndExternalChangeProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.wav.mvproject")
        let suite = "Migration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectStorage(defaults: defaults)
        let data = try fixture(12); try data.write(to: file)
        let result = try storage.readForOpening(from: file)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertNil(storage.lastProjectURL)
        let backup = try XCTUnwrap(storage.commitMigration(result))
        XCTAssertEqual(try Data(contentsOf: backup), data)
        XCTAssertEqual(try storage.read(from: file).version, ProjectFile.currentVersion)
        XCTAssertEqual(storage.lastProjectURL, file)
        XCTAssertNil(try storage.commitMigration(storage.readForOpening(from: file)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        try data.write(to: file)
        let pending = try storage.readForOpening(from: file)
        let external = Data("external update".utf8); try external.write(to: file)
        XCTAssertThrowsError(try storage.commitMigration(pending)) { XCTAssertTrue($0.localizedDescription.contains("再読み込み")) }
        XCTAssertEqual(try Data(contentsOf: file), external)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testBackupAndWriteFailuresPreserveOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.wav.mvproject")
        let data = try fixture(12); try data.write(to: file)
        let suite = "MigrationFailure." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for backupFailure in [true, false] {
            var access = ProjectStorage.FileAccess()
            let failure: (Data, URL) throws -> Void = { _, _ in throw CocoaError(.fileWriteNoPermission) }
            if backupFailure { access.backup = failure } else { access.write = failure }
            let storage = ProjectStorage(defaults: defaults, files: access)
            XCTAssertThrowsError(try storage.commitMigration(storage.readForOpening(from: file)))
            XCTAssertEqual(try Data(contentsOf: file), data)
            XCTAssertNil(storage.lastProjectURL)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(names.count, backupFailure ? 1 : 2)
            for name in names where name.hasSuffix("backup") {
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), data)
            }
        }
    }

    func testLegacyDefaultsAndUnknownNestedFields() throws {
        var root = try json(fixture(12))
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings.removeValue(forKey: "spectrumStyle"); root["settings"] = settings
        var lyrics = try XCTUnwrap(root["lyrics"] as? [String: Any])
        lyrics.removeValue(forKey: "typography"); root["lyrics"] = lyrics
        var layers = try XCTUnwrap(root["visualLayers"] as? [[String: Any]])
        var clips = try XCTUnwrap(layers[0]["clips"] as? [[String: Any]])
        let project = try read(root).project
        XCTAssertEqual(project.settings.spectrumStyle, SpectrumStyle())
        XCTAssertEqual(project.lyrics.typography, LyricsTypography())
        var chain = try XCTUnwrap(clips[0]["effectChain"] as? [String: Any])
        var nodes = try XCTUnwrap(chain["nodes"] as? [[String: Any]])
        nodes[0]["unknownEffectField"] = 10
        chain["nodes"] = nodes; clips[0]["effectChain"] = chain
        layers[0]["clips"] = clips; root["visualLayers"] = layers
        XCTAssertThrowsError(try read(root)) { XCTAssertTrue($0.localizedDescription.contains("unknownEffectField")) }
    }

    @MainActor func testStartupAndExplicitOpenCommitBeforeActivatingEditor() async throws {
        let app = NSApplication.shared
        for startup in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let audio = directory.appendingPathComponent("song.wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 32000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 8000)
            do { let writer = try AVAudioFile(forWriting: audio, settings: format.settings); try writer.write(from: buffer) }
            var root = try json(fixture(12))
            root["visualAssets"] = []
            var layers = try XCTUnwrap(root["visualLayers"] as? [[String: Any]])
            for i in layers.indices { layers[i]["clips"] = [] }
            root["visualLayers"] = layers
            var lyrics = try XCTUnwrap(root["lyrics"] as? [String: Any]); lyrics["clips"] = []; root["lyrics"] = lyrics
            let original = try JSONSerialization.data(withJSONObject: root)
            let file = ProjectStorage.projectURL(for: audio); try original.write(to: file)
            let suite = "MigrationApp." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if startup { defaults.set(file.path, forKey: "lastProjectURL") }
            var backups = 0, writes = 0
            var failBackup = false
            var delegate: AppDelegate!
            var access = ProjectStorage.FileAccess()
            access.backup = { data, target in
                if failBackup { throw CocoaError(.fileWriteNoPermission) }
                XCTAssertEqual(data, original)
                XCTAssertEqual(delegate.placementEditor.duration, 0)
                try data.write(to: target, options: .withoutOverwriting)
                backups += 1
            }
            access.write = { data, target in
                XCTAssertEqual(backups, 1)
                XCTAssertEqual(delegate.placementEditor.duration, 0)
                try data.write(to: target, options: .atomic)
                writes += 1
            }
            delegate = AppDelegate(storage: ProjectStorage(defaults: defaults, files: access), timelineDisplaySettings: TimelineDisplaySettings(defaults: defaults))
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
            if !startup { delegate.openProject(at: file) }
            for _ in 0..<500 {
                if delegate.placementEditor.duration > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(delegate.placementEditor.duration, 0.25, accuracy: 0.001)
            XCTAssertEqual(backups, 1); XCTAssertEqual(writes, 1)
            XCTAssertEqual(try ProjectStorage(defaults: defaults).read(from: file).version, ProjectFile.currentVersion)
            for invalidDuration in [false, true] {
                var rejected = root
                if invalidDuration {
                    var lyrics = try XCTUnwrap(root["lyrics"] as? [String: Any])
                    lyrics["clips"] = [["id": UUID().uuidString, "start": 0, "end": 2, "text": "曲末超過"]]
                    rejected["lyrics"] = lyrics
                }
                failBackup = !invalidDuration
                let rejectedFile = directory.appendingPathComponent("rejected.mvproject")
                let rejectedData = try JSONSerialization.data(withJSONObject: rejected)
                try rejectedData.write(to: rejectedFile)
                delegate.openProject(at: rejectedFile)
                for _ in 0..<500 {
                    if delegate.window.attachedSheet != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let sheet = try XCTUnwrap(delegate.window.attachedSheet)
                delegate.window.endSheet(sheet); sheet.orderOut(nil)
                XCTAssertEqual(delegate.placementEditor.duration, 0.25, accuracy: 0.001)
                XCTAssertTrue(delegate.placementEditor.lyrics.track.clips.isEmpty)
                XCTAssertEqual(backups, 1); XCTAssertEqual(writes, 1)
                XCTAssertEqual(try Data(contentsOf: rejectedFile), rejectedData)
                XCTAssertEqual(ProjectStorage(defaults: defaults).lastProjectURL, file)
            }
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
            delegate.window.delegate = nil
            delegate.window.close()
            delegate = nil
        }
    }
}
