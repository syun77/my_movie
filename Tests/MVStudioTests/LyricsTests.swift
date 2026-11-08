import XCTest
import AppKit
import ImageIO
@testable import MVStudio

final class LyricsTests: XCTestCase {
    func testIntervalsAndValidation() throws {
        var track = LyricsTrack(clips: [LyricClip(start: 0, end: 1, text: "最初"), LyricClip(start: 1, end: 2, text: "次")])
        try track.validate(duration: 2)
        XCTAssertEqual(track.text(at: 0), "最初")
        XCTAssertEqual(track.text(at: 1), "次")
        XCTAssertNil(track.text(at: 2))
        track.clips[1].start = 0.9
        XCTAssertThrowsError(try track.validate())
        track.clips[1].start = 1
        track.outlineWidth = .nan
        XCTAssertThrowsError(try track.validate())
        track.outlineWidth = 3
        track.outlineColor.red = 2
        XCTAssertThrowsError(try track.validate())
    }

    func testOutlineColorWidthAndPersistence() throws {
        var track = LyricsTrack(clips: [LyricClip(start: 0, end: 1, text: "歌詞テロップ\nMusic Video")], outlineWidth: 6, outlineColor: LyricsColor(red: 1, green: 0, blue: 0))
        let outlined = try render(track: track, time: 0.5)
        let thick = redPixels(outlined)
        XCTAssertGreaterThan(thick, 500)
        track.outlineWidth = 1
        XCTAssertLessThan(redPixels(try render(track: track, time: 0.5)), thick)
        track.outlineWidth = 0
        XCTAssertEqual(redPixels(try render(track: track, time: 0.5)), 0)
        track.outlineWidth = 6
        XCTAssertEqual(redPixels(try render(track: track, time: 1)), 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("song.wav")
        let url = ProjectStorage.projectURL(for: audio)
        let project = ProjectFile(audioURL: audio, imageURL: nil, settings: SceneSettings(), lyrics: track, projectURL: url)
        let storage = ProjectStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try storage.save(project, to: url)
        XCTAssertEqual(try storage.read(from: url).lyrics, track)
        let png = URL(fileURLWithPath: "/tmp/my_movie-outline-preview.png")
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, outlined, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func render(track: LyricsTrack, time: Double) throws -> CGImage {
        let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        SceneRenderer.draw(in: context, size: CGSize(width: 1280, height: 720), image: nil, features: nil, settings: SceneSettings(spectrum: false), time: time, lyrics: track)
        return try XCTUnwrap(context.makeImage())
    }

    private func redPixels(_ image: CGImage) -> Int {
        let data = image.dataProvider!.data! as Data
        return stride(from: 0, to: data.count, by: 4).filter { data[$0] > 150 && data[$0 + 1] < 80 && data[$0 + 2] < 80 }.count
    }
}
