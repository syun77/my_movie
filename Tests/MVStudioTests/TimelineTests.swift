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
        XCTAssertEqual(minimum.clips[0].end - minimum.clips[0].start, 1.0 / 30, accuracy: 1e-9)
        let songEnd = try track.dragging(id: track.clips[2].id, part: .move, delta: 100, duration: 20)
        XCTAssertEqual(songEnd.clips.last?.end, 20)
        XCTAssertEqual(try track.dragging(id: id, part: .move, delta: 0.001, duration: 20), track)
    }
    @MainActor func testMouseDragPreviewsThenCommitsOnceAndEscapeRestores() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 112), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = LyricsTimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 112))
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
        let down = geometry.x(at: 2), target = geometry.x(at: 3)
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
        view.mouseDown(with: event(.leftMouseDown, nextGeometry.x(at: 3)))
        view.mouseDragged(with: event(.leftMouseDragged, nextGeometry.x(at: 4)))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(previews.last, view.track)
        view.mouseUp(with: event(.leftMouseUp, nextGeometry.x(at: 4)))
        XCTAssertEqual(commits.count, 1)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-timeline-preview.png"))
        }
    }
}
