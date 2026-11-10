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
        track.outlineColor = .black
        track.typography.fontSize = 0
        XCTAssertThrowsError(try track.validate())
    }

    func testOutlineColorWidthAndPersistence() throws {
        var track = LyricsTrack(clips: [LyricClip(start: 0, end: 1, text: "歌詞テロップ\nMusic Video")], outlineWidth: 6, outlineColor: RGBColor(red: 1, green: 0, blue: 0))
        let outlined = try render(track: track, time: 0.5)
        let thick = redPixels(outlined)
        XCTAssertGreaterThan(thick, 500)
        track.outlineWidth = 1
        XCTAssertLessThan(redPixels(try render(track: track, time: 0.5)), thick)
        track.outlineWidth = 0
        XCTAssertEqual(redPixels(try render(track: track, time: 0.5)), 0)
        track.outlineWidth = 6
        XCTAssertEqual(redPixels(try render(track: track, time: 1)), 0)
        track.typography = LyricsTypography(fontName: "Helvetica", fontSize: 80, x: 500, y: 150)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("song.wav")
        let url = ProjectStorage.projectURL(for: audio)
        let project = ProjectFile(audioURL: audio, settings: SceneSettings(), lyrics: track, projectURL: url)
        let storage = ProjectStorage(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try storage.save(project, to: url)
        XCTAssertEqual(try storage.read(from: url).lyrics, track)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var lyrics = try XCTUnwrap(saved["lyrics"] as? [String: Any])
        lyrics.removeValue(forKey: "typography")
        saved["lyrics"] = lyrics
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        XCTAssertEqual(try storage.read(from: url).lyrics.typography, LyricsTypography())
        let png = URL(fileURLWithPath: "/tmp/my_movie-outline-preview.png")
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, outlined, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testTypographyChangesRenderedGlyphs() throws {
        var track = LyricsTrack(clips: [LyricClip(start: 0, end: 1, text: "Music Video")], outlineWidth: 0)
        let original = whiteBounds(try render(track: track, time: 0.5))
        track.typography.x += 300
        track.typography.y -= 150
        let moved = whiteBounds(try render(track: track, time: 0.5))
        XCTAssertEqual(moved.midX - original.midX, 200, accuracy: 1)
        XCTAssertEqual(moved.minY - original.minY, -100, accuracy: 1)
        track.typography.fontSize *= 2
        let enlarged = whiteBounds(try render(track: track, time: 0.5))
        XCTAssertGreaterThan(enlarged.height, moved.height * 1.8)
        track.typography.fontName = "Courier"
        let courier = whiteBounds(try render(track: track, time: 0.5))
        XCTAssertNotEqual(courier.width, enlarged.width)
        track.typography.fontName = "MVStudio-Missing-Test-Font"
        XCTAssertEqual(whiteBounds(try render(track: track, time: 0.5)), enlarged)
    }

    private func whiteBounds(_ image: CGImage) -> CGRect {
        let data = image.dataProvider!.data! as Data
        var bounds = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4
                if data[offset] > 200, data[offset + 1] > 200, data[offset + 2] > 200 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds
    }

    private func render(track: LyricsTrack, time: Double) throws -> CGImage {
        let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        LyricsRenderer.draw(in: context, size: CGSize(width: 1280, height: 720), track: track, time: time)
        return try XCTUnwrap(context.makeImage())
    }

    private func redPixels(_ image: CGImage) -> Int {
        let data = image.dataProvider!.data! as Data
        return stride(from: 0, to: data.count, by: 4).filter { data[$0] > 150 && data[$0 + 1] < 80 && data[$0 + 2] < 80 }.count
    }
}
