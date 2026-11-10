import AppKit
import XCTest
@testable import MVStudio

final class PresetStoreTests: XCTestCase {
    @MainActor func testPresetsPersistByCategoryAndCanBeAppliedFromMenu() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lyrics = PresetStore<LyricsStyle>(directory: directory)
        let spectrum = PresetStore<SpectrumSettings>(directory: directory)
        let typography = LyricsTypography(fontName: "Helvetica-Bold", fontSize: 72, x: 640, y: 840)
        let lyricsStyle = LyricsStyle(outlineWidth: 6, outlineColor: RGBColor(red: 0, green: 0, blue: 1), typography: typography)
        let spectrumStyle = SpectrumStyle(shape: .line, resolution: .minimal, layout: SpectrumLayout(x: 10))
        XCTAssertTrue(try lyrics.load().isEmpty)
        XCTAssertTrue(try spectrum.load().isEmpty)
        try lyrics.save(name: "  サビ  ", settings: lyricsStyle)
        try spectrum.save(name: "サビ", settings: SpectrumSettings(shown: false, style: spectrumStyle))
        XCTAssertThrowsError(try lyrics.save(name: "サビ", settings: LyricsTrack().style))
        XCTAssertThrowsError(try lyrics.save(name: " ", settings: lyricsStyle))
        var invalidStyle = lyricsStyle
        invalidStyle.typography.fontSize = 0
        XCTAssertThrowsError(try lyrics.save(name: "不正", settings: invalidStyle))

        let reopened = PresetStore<LyricsStyle>(directory: directory)
        let presets = try reopened.load()
        XCTAssertEqual(presets.map(\.name), ["サビ"])
        XCTAssertEqual(presets.map(\.settings), [lyricsStyle])
        let visualizer = try XCTUnwrap(PresetStore<SpectrumSettings>(directory: directory).load().first)
        XCTAssertEqual(visualizer.name, "サビ")
        XCTAssertFalse(visualizer.settings.shown)
        XCTAssertEqual(visualizer.settings.style, spectrumStyle)

        try lyrics.save(name: "イントロ", settings: lyricsStyle)
        var applied: LyricsStyle?
        var edited = lyricsStyle
        let picker = PresetMenu(store: reopened, finishEditing: { true }, current: { edited }, apply: { applied = $0 })
        let menu = try XCTUnwrap(picker.button.menu)
        let unselectedTitle = "選択中のプリセットを上書き"
        picker.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.item(withTitle: unselectedTitle)?.isEnabled, false)
        let item = try XCTUnwrap(menu.item(withTitle: "サビ"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(applied, lyricsStyle)

        edited.typography.fontSize = 95
        picker.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.item(withTitle: "サビ")?.state, .on)
        let overwrite = try XCTUnwrap(menu.item(withTitle: "「サビ」を上書き"))
        XCTAssertTrue(overwrite.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(overwrite.action), to: overwrite.target, from: overwrite))

        let updated = try reopened.load()
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated.first { $0.name == "サビ" }?.settings, edited)
        XCTAssertEqual(updated.first { $0.name == "イントロ" }?.settings, lyricsStyle)
        XCTAssertEqual(try spectrum.load().first?.settings.style, spectrumStyle)
        XCTAssertThrowsError(try reopened.overwrite(name: "存在しないプリセット", settings: edited))
        XCTAssertThrowsError(try reopened.overwrite(name: "サビ", settings: invalidStyle))
        XCTAssertEqual(try reopened.load().first { $0.name == "サビ" }?.settings, edited)

        picker.clearSelection()
        picker.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.item(withTitle: unselectedTitle)?.isEnabled, false)
        XCTAssertEqual(menu.item(withTitle: "サビ")?.state, .off)
    }
}
