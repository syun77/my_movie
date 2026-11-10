import AppKit
import XCTest
@testable import MVStudio

final class TimelineTests: XCTestCase {
    func testGeometryFollowsPlaybackAndClampsAtSongEdges() {
        let middle = TimelineGeometry(time: 50, duration: 100, span: 12, width: 1000)
        XCTAssertEqual(middle.origin, 44)
        XCTAssertEqual(middle.time(at: middle.x(at: 49.375)), 49.375, accuracy: 1e-9)
        XCTAssertEqual(TimelineGeometry(time: 0, duration: 100, span: 12, width: 1000).origin, 0)
        XCTAssertEqual(TimelineGeometry(time: 99, duration: 100, span: 12, width: 1000).origin, 88)
        XCTAssertEqual(TimelineGeometry(time: 2, duration: 3, span: 12, width: 1000).origin, 0)
        XCTAssertEqual(TimelineGeometry.label(61.234), "01:01.234")
    }
    @MainActor func testShiftWheelPansWithoutSeekingAndStopsAtSongEdges() throws {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        view.duration = 100
        view.currentTime = 25
        view.isEnabled = true
        view.onSeek = { _ in XCTFail("横スクロールでシークしない") }
        view.onWheelZoom = { _ in XCTFail("横スクロールでズームしない") }

        func wheel(y: Int32 = 0, x: Int32 = 0, units: CGScrollEventUnit = .line,
                   shift: Bool = true) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                              wheel1: y, wheel2: x, wheel3: 0))
            if shift { event.flags = .maskShift }
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }

        let start = view.geometry.origin
        try wheel(y: -1, shift: false)
        XCTAssertEqual(view.geometry.origin, start)
        try wheel(y: -1)
        let scrolled = view.geometry.origin
        XCTAssertGreaterThan(scrolled, start)
        XCTAssertEqual(view.currentTime, 25)
        XCTAssertEqual(view.visibleSpan, 12)
        view.currentTime = 26
        view.imageMode = true
        XCTAssertEqual(view.geometry.origin, scrolled)

        try wheel(x: -10, units: .pixel)
        XCTAssertGreaterThan(view.geometry.origin, scrolled)
        try wheel(y: -1000)
        XCTAssertEqual(view.geometry.origin, 88)
        try wheel(y: 1000)
        XCTAssertEqual(view.geometry.origin, 0)
        view.followPlayhead()
        XCTAssertEqual(view.geometry.origin, 20)
        view.visibleSpan = view.duration
        try wheel(y: -1000)
        XCTAssertEqual(view.geometry.origin, 0)
    }

    @MainActor func testOptionWheelSeeksByVisibleSpanAndRevealsOffscreenPlayhead() throws {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        view.duration = 120
        view.currentTime = 30
        view.isEnabled = true
        view.onSeek = { [unowned view] in view.currentTime = $0 }
        view.onWheelZoom = { _ in XCTFail("Option＋ホイールでズームしない") }

        func wheel(_ lines: Int32, modifiers: CGEventFlags = .maskAlternate) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                              wheel1: lines, wheel2: 0, wheel3: 0))
            event.flags = modifiers
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }

        view.visibleSpan = 2
        try wheel(-1)
        let fineStep = view.currentTime - 30
        XCTAssertGreaterThan(fineStep, 0)
        try wheel(1)
        XCTAssertEqual(view.currentTime, 30, accuracy: 1e-9)

        view.imageMode = true
        view.visibleSpan = 20
        try wheel(-1)
        XCTAssertEqual(view.currentTime - 30, fineStep * 10, accuracy: 1e-9)
        try wheel(-1000, modifiers: .maskShift)
        XCTAssertGreaterThan(view.geometry.origin, view.currentTime)
        try wheel(1)
        XCTAssertEqual(view.currentTime, 30, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(view.geometry.origin, view.currentTime)
        XCTAssertGreaterThanOrEqual(view.geometry.origin + view.geometry.span, view.currentTime)

        try wheel(1000)
        XCTAssertEqual(view.currentTime, 0)
        try wheel(-1000)
        XCTAssertEqual(view.currentTime, view.duration)
    }

    private func sample() throws -> LyricsTrack {
        let first = try LyricsTrack().adding(at: 1, duration: 20)
        let second = try first.track.adding(at: 2, duration: 20)
        return try second.track.adding(at: 10, duration: 20).track
    }
    func testMoveAndTrimPreserveChainsAndClampAtBoundaries() throws {
        let track = try sample()
        let id = track.clips[0].id
        let moved = try track.dragging(id: id, part: .move, delta: 100, duration: 20)
        XCTAssertEqual(moved.clips.map(\.start), [6, 8, 10])
        XCTAssertEqual(moved.clips.map(\.end), [8, 10, 12])
        let left = try track.dragging(id: id, part: .move, delta: -100, duration: 20)
        XCTAssertEqual(left.clips[0].start, 0)
        XCTAssertEqual(left.clips[1].start, 2)
        let trim = try track.dragging(id: id, part: .end, delta: 1, duration: 20)
        XCTAssertEqual(trim.clips.map(\.start), [1, 4, 10])
        XCTAssertEqual(trim.clips.map(\.end), [4, 6, 12])
        let leftTrim = try track.dragging(id: track.clips[1].id, part: .start, delta: 0.5, duration: 20)
        XCTAssertEqual(leftTrim.clips[1].start, 3.5)
        XCTAssertEqual(leftTrim.clips[1].end, 5)
        XCTAssertNil(leftTrim.clips[1].predecessorID)
        let minimum = try track.dragging(id: id, part: .end, delta: -100, duration: 20)
        XCTAssertEqual(minimum.clips[0].end - minimum.clips[0].start, 0.125, accuracy: 1e-9)
        let songEnd = try track.dragging(id: track.clips[2].id, part: .move, delta: 100, duration: 20)
        XCTAssertEqual(songEnd.clips.last?.end, 20)
        XCTAssertEqual(try track.dragging(id: id, part: .move, delta: 0.001, duration: 20), track)
    }
    @MainActor func testMouseDragPreviewsThenCommitsOnceAndEscapeRestores() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 112), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 112))
        window.contentView = view
        view.track = try sample(); view.duration = 20; view.currentTime = 4; view.isEnabled = true
        var commits = [LyricsTrack](); var previews = [LyricsTrack](); var begins = 0
        view.onBeginEdit = { begins += 1 }
        view.onPreview = { previews.append($0) }
        view.onCommit = { value, _ in commits.append(value); view.track = value }
        func event(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: 55), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let geometry = view.geometry
        let down = view.x(at: 2), target = view.x(at: 3)
        view.mouseDown(with: event(.leftMouseDown, down))
        view.currentTime = 15
        XCTAssertEqual(view.geometry.origin, geometry.origin, "ドラッグ中は表示範囲を固定")
        view.mouseDragged(with: event(.leftMouseDragged, target))
        XCTAssertEqual(commits.count, 0)
        XCTAssertEqual(previews.last?.clips.first?.start, 2)
        view.mouseUp(with: event(.leftMouseUp, target))
        XCTAssertEqual(commits.count, 1); XCTAssertEqual(begins, 1)
        XCTAssertEqual(view.track.clips[1].start, 4)
        view.currentTime = 4
        let nextGeometry = view.geometry
        view.mouseDown(with: event(.leftMouseDown, TimelineView.gutter + nextGeometry.x(at: 3)))
        view.mouseDragged(with: event(.leftMouseDragged, TimelineView.gutter + nextGeometry.x(at: 4)))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(previews.last, view.track)
        view.mouseUp(with: event(.leftMouseUp, TimelineView.gutter + nextGeometry.x(at: 4)))
        XCTAssertEqual(commits.count, 1)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-timeline-preview.png"))
        }
    }
    @MainActor func testTrimHoverHighlightsBothClipTypes() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 210)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TimelineView(frame: frame)
        window.contentView = view
        view.duration = 20
        view.isEnabled = true

        var images = ImageTrack()
        let project = URL(fileURLWithPath: "/tmp/trim.mvproject")
        let asset = images.register(url: URL(fileURLWithPath: "/tmp/trim.png"), projectURL: project)
        images.layers[2].clips = [ImageClip(assetID: asset, start: 2, end: 4)]
        view.images = images
        view.track = LyricsTrack(clips: [LyricClip(start: 2, end: 4, text: "歌詞")])
        var trimmedLyrics: LyricsTrack?
        var trimmedImages: ImageTrack?
        view.onCommit = { value, _ in trimmedLyrics = value }
        view.onImageCommit = { value, _ in trimmedImages = value }

        func event(_ type: NSEvent.EventType, x: Double, y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func hasYellow(at x: Double) throws -> Bool {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let column = Int(x * Double(bitmap.pixelsWide) / view.bounds.width)
            return (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.75 && color.greenComponent > 0.6 && color.blueComponent < 0.5
            }
        }
        for imageMode in [false, true] {
            view.imageMode = imageMode
            let y = imageMode ? 68.0 : 55.0
            let left = view.x(at: 2) + 4
            let right = view.x(at: 4) - 4
            view.mouseMoved(with: event(.mouseMoved, x: left, y: y))
            XCTAssertTrue(try hasYellow(at: left))
            XCTAssertFalse(try hasYellow(at: right))
            view.mouseMoved(with: event(.mouseMoved, x: right, y: y))
            XCTAssertFalse(try hasYellow(at: left))
            XCTAssertTrue(try hasYellow(at: right))
            view.mouseMoved(with: event(.mouseMoved, x: view.x(at: 3), y: y))
            XCTAssertFalse(try hasYellow(at: right))

            let edge = imageMode ? right : left
            let destination = edge + view.geometry.pointsPerSecond * 0.5
            view.mouseDown(with: event(.leftMouseDown, x: edge, y: y))
            view.mouseDragged(with: event(.leftMouseDragged, x: destination, y: y))
            view.mouseUp(with: event(.leftMouseUp, x: destination, y: y))
        }
        XCTAssertEqual(trimmedLyrics?.clips.first?.start, 2.5)
        XCTAssertEqual(trimmedLyrics?.clips.first?.end, 4)
        XCTAssertEqual(trimmedImages?.clips.first?.start, 2)
        XCTAssertEqual(trimmedImages?.clips.first?.end, 4.5)
    }

}
