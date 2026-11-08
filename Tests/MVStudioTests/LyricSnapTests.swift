import XCTest
@testable import MVStudio

final class LyricSnapTests: XCTestCase {
    @MainActor func testEditorAddsOnSixteenthNotes() {
        let editor = LyricsEditor()
        _ = editor.view
        editor.duration = 10; editor.setAvailable(true)
        editor.snapGrid = TimelineSnapGrid(bpm: 100, origin: 0.04)
        editor.currentTime = 1.12
        editor.perform(NSSelectorFromString("addClip"))
        XCTAssertEqual(editor.track.clips[0].start, 1.09, accuracy: 1e-9)
    }

    func testGridUsesBPMAndBeatOriginWithoutFrameRounding() throws {
        let grid = TimelineSnapGrid(bpm: 137, origin: 0.07)
        let expected = grid.origin + 9 * grid.step
        let added = try LyricsTrack().adding(at: expected + 0.02, duration: 10, grid: grid)
        XCTAssertEqual(added.clip.start, expected, accuracy: 1e-9)
        XCTAssertEqual((added.clip.end - grid.origin) / grid.step, ((added.clip.end - grid.origin) / grid.step).rounded(), accuracy: 1e-9)
        let moved = try added.track.dragging(id: added.clip.id, part: .move, delta: 0.2, duration: 10, grid: grid)
        XCTAssertEqual(moved.clips[0].start, grid.nearest(expected + 0.2), accuracy: 1e-9)
        XCTAssertEqual(moved.clips[0].end - moved.clips[0].start, added.clip.end - added.clip.start, accuracy: 1e-9)
        let trimmed = try added.track.dragging(id: added.clip.id, part: .end, delta: 100, duration: 9.98, grid: grid)
        XCTAssertLessThanOrEqual(trimmed.clips[0].end, 9.98)
        XCTAssertEqual((trimmed.clips[0].end - grid.origin) / grid.step, ((trimmed.clips[0].end - grid.origin) / grid.step).rounded(), accuracy: 1e-9)
    }
    func testNewLinkedClipKeepsAttachmentAndSnapsEnd() throws {
        let grid = TimelineSnapGrid(bpm: 100, origin: 0.04)
        let first = try LyricsTrack().adding(at: 1, duration: 10, grid: grid)
        let next = try first.track.adding(at: first.clip.start + 0.2, duration: 10, grid: grid)
        XCTAssertEqual(next.clip.start, first.clip.end)
        XCTAssertEqual(next.clip.predecessorID, first.clip.id)
        XCTAssertThrowsError(try grid.snap(0, within: 0...0.01))
    }
}
