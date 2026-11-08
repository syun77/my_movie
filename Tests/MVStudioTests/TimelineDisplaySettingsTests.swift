import AppKit
import XCTest
@testable import MVStudio

final class TimelineDisplaySettingsTests: XCTestCase {
    @MainActor func testSpanPersistsAndRestoresEditorWithoutSavingOnLoad() throws {
        let suite = "MVStudioTimeline." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TimelineDisplaySettings(defaults: defaults)
        XCTAssertEqual(settings.visibleSpan, 12)
        let editor = PlacementEditor()
        _ = editor.view
        var saves = 0
        editor.onVisibleSpanChange = { settings.visibleSpan = $0; saves += 1 }
        editor.visibleSpan = 7.5
        XCTAssertEqual(saves, 0)
        editor.perform(NSSelectorFromString("changeZoom"))
        XCTAssertEqual(saves, 1)
        let restored = TimelineDisplaySettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restored.visibleSpan, 7.5)
        let reopened = PlacementEditor()
        _ = reopened.view
        reopened.visibleSpan = restored.visibleSpan
        reopened.lyrics.load(LyricsTrack())
        let timeline = try XCTUnwrap(reopened.view.subviews.first { $0 is TimelineView } as? TimelineView)
        XCTAssertEqual(timeline.visibleSpan, 7.5)
        XCTAssertEqual(reopened.visibleSpan, 7.5)
        for invalid in [Double.nan, .infinity, 1, 301] {
            settings.visibleSpan = invalid
            XCTAssertEqual(settings.visibleSpan, 7.5)
        }
        defaults.set(999.0, forKey: "timelineVisibleSpan")
        XCTAssertEqual(settings.visibleSpan, 12)
    }
    @MainActor func testLongRangeAndWholeSongFollowDuration() throws {
        let suite = "MVStudioTimeline." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TimelineDisplaySettings(defaults: defaults)
        settings.visibleSpan = 300
        settings.showsWholeSong = true
        let restored = TimelineDisplaySettings(defaults: defaults)
        XCTAssertEqual(restored.visibleSpan, 300)
        XCTAssertTrue(restored.showsWholeSong)
        let editor = PlacementEditor()
        _ = editor.view
        editor.visibleSpan = restored.visibleSpan
        editor.showsWholeSong = restored.showsWholeSong
        editor.duration = 421
        editor.currentTime = 400
        XCTAssertEqual(editor.timeline.geometry.span, 421)
        XCTAssertEqual(editor.timeline.geometry.origin, 0)
        editor.duration = 1.5
        XCTAssertEqual(editor.timeline.geometry.span, 1.5)
        editor.duration = 0
        XCTAssertEqual(editor.timeline.visibleSpan, 300)
        editor.duration = 421
        editor.showsWholeSong = false
        XCTAssertEqual(editor.timeline.visibleSpan, 300)
        let toggle = try XCTUnwrap(editor.view.subviews.first?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "曲全体" })
        var saved: Bool?
        editor.onWholeSongChange = { saved = $0 }
        toggle.performClick(nil)
        XCTAssertEqual(saved, true)
        XCTAssertEqual(editor.timeline.visibleSpan, 421)
        for span in [2.0, 12, 300, 7200] {
            let geometry = TimelineGeometry(time: 0, duration: span, span: span, width: 800)
            XCTAssertLessThanOrEqual(span / geometry.tickInterval, 10)
            XCTAssertEqual(geometry.time(at: geometry.x(at: span)), span, accuracy: 1e-8)
        }
    }

}
