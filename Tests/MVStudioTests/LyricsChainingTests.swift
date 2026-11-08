import XCTest
@testable import MVStudio

final class LyricsChainingTests: XCTestCase {
    func testAdditionAndFollowingAcrossMultipleClips() throws {
        let first = try LyricsTrack().adding(at: 1, duration: 20)
        let second = try first.track.adding(at: 1.5, duration: 20)
        XCTAssertEqual(second.clip.start, 3)
        XCTAssertEqual(second.clip.predecessorID, first.clip.id)
        let third = try second.track.adding(at: 1.5, duration: 20)
        XCTAssertEqual(third.clip.start, 5)
        XCTAssertEqual(third.clip.predecessorID, second.clip.id)
        let independent = try third.track.adding(at: 10, duration: 20)
        XCTAssertNil(independent.clip.predecessorID)
        XCTAssertEqual(independent.clip.start, 10)
        let moved = try independent.track.updating(id: first.clip.id, start: 2, end: 3, text: "先頭", duration: 20)
        XCTAssertEqual(moved.clips.map(\.start), [2, 4, 6, 10])
        XCTAssertEqual(moved.clips.map(\.end), [4, 6, 8, 12])
        let resized = try moved.updating(id: first.clip.id, start: 2, end: 5, text: "先頭", duration: 20)
        XCTAssertEqual(resized.clips.map(\.start), [2, 5, 7, 10])
        XCTAssertEqual(resized.clips.map(\.end), [5, 7, 9, 12])
        XCTAssertThrowsError(try resized.updating(id: first.clip.id, start: 2, end: 7, text: "先頭", duration: 20))
        let decoded = try JSONDecoder().decode(LyricsTrack.self, from: JSONEncoder().encode(resized))
        XCTAssertEqual(decoded, resized)
        XCTAssertEqual(try decoded.updating(id: first.clip.id, start: 2, end: 4, text: "復元", duration: 20).clips[2].start, 6)
    }

    func testDetachDeleteBoundariesAndInvalidReferences() throws {
        let first = try LyricsTrack().adding(at: 0, duration: 10)
        let second = try first.track.adding(at: 1, duration: 10)
        let third = try second.track.adding(at: 2.5, duration: 10)
        let detached = try third.track.settingChain(id: second.clip.id, enabled: false, duration: 10)
        let moved = try detached.updating(id: first.clip.id, start: 0, end: 1, text: "先頭", duration: 10)
        XCTAssertEqual(moved.clips[1].start, 2)
        XCTAssertEqual(moved.clips[2].start, 4)
        let relinked = try moved.settingChain(id: second.clip.id, enabled: true, duration: 10)
        XCTAssertEqual(relinked.clips[1].start, 1)
        XCTAssertEqual(relinked.clips[2].start, 3)
        let deleted = try third.track.removing(id: second.clip.id, duration: 10)
        XCTAssertNil(deleted.clips[1].predecessorID)
        XCTAssertEqual(deleted.clips[1].start, 4)
        XCTAssertThrowsError(try third.track.updating(id: first.clip.id, start: 8, end: 2, text: "曲末超過", duration: 10))
        XCTAssertThrowsError(try first.track.adding(at: 10, duration: 10))
        let atEnd = try first.track.adding(at: 2, duration: 10)
        XCTAssertNil(atEnd.clip.predecessorID, "終了境界は既存テロップに重ならない")
        let nearEnd = try LyricsTrack().adding(at: 9, duration: 10)
        XCTAssertThrowsError(try nearEnd.track.adding(at: 9.5, duration: 10))
        var invalid = third.track
        invalid.clips[1].predecessorID = invalid.clips[2].id
        XCTAssertThrowsError(try invalid.validate())
        invalid.clips[1].predecessorID = UUID()
        XCTAssertThrowsError(try invalid.validate())
    }
}
