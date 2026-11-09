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

    @MainActor func testCommandWheelZoomSharesDisplayRangeAndKeepsPlaybackPosition() async throws {
        let editor = PlacementEditor()
        _ = editor.view
        editor.duration = 421
        editor.currentTime = 25
        editor.setAvailable(true)
        var savedSpans: [Double] = []
        var savedWholeSong: [Bool] = []
        editor.onVisibleSpanChange = { savedSpans.append($0) }
        editor.onWholeSongChange = { savedWholeSong.append($0) }

        func wheel(_ lines: Int32, command: Bool = true) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                              wheel1: lines, wheel2: 0, wheel3: 0))
            if command { event.flags = .maskCommand }
            editor.timeline.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }

        try wheel(1, command: false)
        XCTAssertEqual(editor.visibleSpan, 12)
        try wheel(1)
        XCTAssertLessThan(editor.visibleSpan, 12)
        XCTAssertEqual(editor.timeline.visibleSpan, 12)
        try wheel(1)
        XCTAssertEqual(editor.visibleSpan, 12 / pow(1.15, 2), accuracy: 1e-9)
        XCTAssertEqual(editor.timeline.visibleSpan, 12)
        try await waitForZoom(editor, checkingIntermediateFrames: true)
        XCTAssertEqual(editor.timeline.visibleSpan, editor.visibleSpan)
        XCTAssertEqual(savedSpans.last, editor.visibleSpan)
        XCTAssertEqual(editor.timeline.currentTime, 25)

        let slider = try XCTUnwrap(editor.view.subviews.first?.subviews.compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.doubleValue, editor.visibleSpan)

        editor.restoreMode(true)
        var images = ImageTrack()
        let projectURL = URL(fileURLWithPath: "/tmp/zoom.mvproject")
        let asset = images.register(url: URL(fileURLWithPath: "/tmp/zoom.png"), projectURL: projectURL)
        var clip = ImageClip(assetID: asset, start: 24, end: 26)
        _ = clip.setKey(.scale, at: 25, value: 120)
        images.layers[2].clips = [clip]
        editor.images.load(images, projectURL: nil)
        editor.timeline.revealAutomation(in: 3)
        try wheel(-2)
        XCTAssertEqual(editor.visibleSpan, 12, accuracy: 1e-9)
        try await waitForZoom(editor)
        XCTAssertEqual(editor.timeline.visibleSpan, editor.visibleSpan)
        try wheel(100)
        XCTAssertEqual(editor.visibleSpan, 2)
        let saveCount = savedSpans.count
        try wheel(1)
        XCTAssertEqual(savedSpans.count, saveCount)
        try wheel(-100)
        XCTAssertEqual(editor.visibleSpan, 300)

        editor.showsWholeSong = true
        try wheel(-1)
        XCTAssertTrue(editor.showsWholeSong)
        try wheel(1)
        XCTAssertEqual(savedWholeSong, [false])
        XCTAssertFalse(editor.showsWholeSong)
        XCTAssertEqual(editor.timeline.visibleSpan, 421)
        try await waitForZoom(editor)
        XCTAssertEqual(editor.timeline.visibleSpan, 300)
        XCTAssertTrue(editor.timeline.expandedLayerSlots.contains(3))
        XCTAssertEqual(editor.images.track, images)

        try wheel(1)
        slider.doubleValue = 40
        editor.perform(NSSelectorFromString("changeZoom"))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(editor.timeline.visibleSpan, 40, "スライダーの操作で補間を中断する")
        XCTAssertEqual(savedSpans.last, 40)

        editor.duration = 1.5
        editor.showsWholeSong = true
        try wheel(1)
        XCTAssertTrue(editor.showsWholeSong)
        XCTAssertEqual(editor.timeline.visibleSpan, 1.5)
        editor.setAvailable(false)
        try wheel(-1)
        XCTAssertEqual(savedWholeSong, [false])
    }

    @MainActor private func waitForZoom(_ editor: PlacementEditor, checkingIntermediateFrames: Bool = false) async throws {
        let start = editor.timeline.visibleSpan
        let target = editor.visibleSpan
        var sawIntermediateFrame = false
        for _ in 0..<50 {
            let span = editor.timeline.visibleSpan
            if span == target {
                if checkingIntermediateFrames { XCTAssertTrue(sawIntermediateFrame) }
                return
            }
            if span != start {
                XCTAssertTrue((min(start, target)...max(start, target)).contains(span))
                sawIntermediateFrame = true
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("横ズームが目標の表示範囲へ到達しません")
    }

}
