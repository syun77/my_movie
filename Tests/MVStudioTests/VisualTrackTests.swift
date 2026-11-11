import AppKit
import ImageIO
import XCTest
@testable import MVStudio

final class VisualTrackTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/image-test/song.wav.mvproject")
    private func sample() throws -> (VisualTrack, UUID) {
        var visuals = VisualTrack()
        let id = visuals.register(url: projectURL.deletingLastPathComponent().appendingPathComponent("background.png"), projectURL: projectURL)
        visuals = try visuals.adding(assetID: id, at: 1, slot: 1, duration: 10, grid: TimelineSnapGrid()).track
        return (visuals, id)
    }
    func testPlacementLayerConstraintsAndSnapping() throws {
        let (visuals, id) = try sample()
        XCTAssertThrowsError(try visuals.adding(assetID: id, at: 2, slot: 1, duration: 10, grid: TimelineSnapGrid()))
        let overlap = try visuals.adding(assetID: id, at: 2, slot: 2, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(overlap.track.active(at: 2.5).count, 2)
        XCTAssertEqual(overlap.track.active(at: 3).count, 1)
        XCTAssertThrowsError(try visuals.adding(assetID: id, at: 1, slot: 4, duration: 10, grid: TimelineSnapGrid()))
        var invalid = visuals; invalid.layers.append(VisualLayer(slot: 4)); XCTAssertThrowsError(try invalid.validate())
        let grid = TimelineSnapGrid(bpm: 137, origin: 0.04)
        let addition = try visuals.adding(assetID: id, at: 7.12, slot: 1, duration: 10, grid: grid)
        XCTAssertEqual(addition.clip.start, grid.nearest(7.12), accuracy: 1e-9)
        XCTAssertThrowsError(try addition.track.adding(assetID: UUID(), at: 0, slot: 3, duration: 10, grid: grid))
    }
    func testMoveTrimAndLayerMoveAreAtomic() throws {
        let (visuals, id) = try sample()
        let more = try visuals.adding(assetID: id, at: 5, slot: 1, duration: 10, grid: TimelineSnapGrid()).track
        let clip = more.layers[0].clips[0]
        let moved = try more.dragging(id: clip.id, part: .move, delta: 100, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(moved.layers[0].clips[0].start, 3)
        XCTAssertEqual(moved.layers[0].clips[0].end, 5)
        XCTAssertEqual(moved.layers[0].clips[1], more.layers[0].clips[1])
        let trimmed = try more.dragging(id: clip.id, part: .start, delta: 1, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(trimmed.layers[0].clips[0].start, 2); XCTAssertEqual(trimmed.layers[0].clips[0].end, 3)
        let differentLayer = try more.updating(clip, slot: 3, duration: 10)
        XCTAssertEqual(differentLayer.slot(of: clip.id), 3)
        let collision = try more.adding(assetID: id, at: 1, slot: 2, duration: 10, grid: TimelineSnapGrid()).track
        XCTAssertThrowsError(try collision.updating(clip, slot: 2, duration: 10))
        var invalid = clip; invalid.end = 11
        XCTAssertThrowsError(try more.updating(invalid, slot: 1, duration: 10))
    }
    func testAssetReplacementDeletionAndUnusedPersistence() throws {
        var (visuals, id) = try sample()
        visuals = try visuals.adding(assetID: id, at: 1, slot: 2, duration: 10, grid: TimelineSnapGrid()).track
        let replacement = projectURL.deletingLastPathComponent().appendingPathComponent("new.png")
        let replaced = try visuals.replacingAsset(id: id, url: replacement, projectURL: projectURL)
        XCTAssertEqual(replaced.clips, visuals.clips)
        XCTAssertEqual(replaced.asset(id)?.reference.resolve(projectURL: projectURL), replacement)
        XCTAssertThrowsError(try visuals.removingAsset(id: id, includingPlacements: false))
        let removed = try visuals.removingAsset(id: id, includingPlacements: true)
        XCTAssertTrue(removed.clips.isEmpty); XCTAssertTrue(removed.assets.isEmpty)
        var unused = visuals
        for clip in visuals.clips { unused = unused.removingClip(id: clip.id) }
        XCTAssertEqual(unused.assets.count, 1)
        let project = ProjectFile(audioURL: projectURL.deletingPathExtension(), visuals: unused, settings: SceneSettings(), projectURL: projectURL)
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        try decoded.validate(); XCTAssertEqual(decoded.version, ProjectFile.currentVersion); XCTAssertEqual(decoded.visuals, unused)
        let existingID = visuals.register(url: replacement, projectURL: projectURL)
        let merged = try visuals.replacingAsset(id: id, url: replacement, projectURL: projectURL)
        XCTAssertEqual(merged.assets.count, 1); XCTAssertTrue(merged.clips.allSatisfy { $0.assetID == existingID })
    }
    func testActiveIntervalsIncludeStartAndExcludeEnd() throws {
        let (visuals, _) = try sample()
        XCTAssertTrue(visuals.active(at: 0.999).isEmpty); XCTAssertEqual(visuals.active(at: 1).count, 1); XCTAssertTrue(visuals.active(at: 3).isEmpty)
    }
}
