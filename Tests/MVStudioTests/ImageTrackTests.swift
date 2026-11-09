import AppKit
import ImageIO
import XCTest
@testable import MVStudio

final class ImageTrackTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/image-test/song.wav.mvproject")
    private func sample() throws -> (ImageTrack, UUID) {
        var images = ImageTrack()
        let id = images.register(url: projectURL.deletingLastPathComponent().appendingPathComponent("background.png"), projectURL: projectURL)
        images = try images.adding(assetID: id, at: 1, slot: 1, duration: 10, grid: TimelineSnapGrid()).track
        return (images, id)
    }
    func testPlacementLayerConstraintsAndSnapping() throws {
        let (images, id) = try sample()
        XCTAssertThrowsError(try images.adding(assetID: id, at: 2, slot: 1, duration: 10, grid: TimelineSnapGrid()))
        let overlap = try images.adding(assetID: id, at: 2, slot: 2, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(overlap.track.active(at: 2.5).count, 2)
        XCTAssertEqual(overlap.track.active(at: 3).count, 1)
        XCTAssertThrowsError(try images.adding(assetID: id, at: 1, slot: 4, duration: 10, grid: TimelineSnapGrid()))
        var invalid = images; invalid.layers.append(ImageLayer(slot: 4)); XCTAssertThrowsError(try invalid.validate())
        let grid = TimelineSnapGrid(bpm: 137, origin: 0.04)
        let addition = try images.adding(assetID: id, at: 7.12, slot: 1, duration: 10, grid: grid)
        XCTAssertEqual(addition.clip.start, grid.nearest(7.12), accuracy: 1e-9)
        XCTAssertThrowsError(try addition.track.adding(assetID: UUID(), at: 0, slot: 3, duration: 10, grid: grid))
    }
    func testMoveTrimAndLayerMoveAreAtomic() throws {
        let (images, id) = try sample()
        let more = try images.adding(assetID: id, at: 5, slot: 1, duration: 10, grid: TimelineSnapGrid()).track
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
        var (images, id) = try sample()
        images = try images.adding(assetID: id, at: 1, slot: 2, duration: 10, grid: TimelineSnapGrid()).track
        let replacement = projectURL.deletingLastPathComponent().appendingPathComponent("new.png")
        let replaced = try images.replacingAsset(id: id, url: replacement, projectURL: projectURL)
        XCTAssertEqual(replaced.clips, images.clips)
        XCTAssertEqual(replaced.asset(id)?.reference.resolve(projectURL: projectURL), replacement)
        XCTAssertThrowsError(try images.removingAsset(id: id, includingPlacements: false))
        let removed = try images.removingAsset(id: id, includingPlacements: true)
        XCTAssertTrue(removed.clips.isEmpty); XCTAssertTrue(removed.assets.isEmpty)
        var unused = images
        for clip in images.clips { unused = unused.removingClip(id: clip.id) }
        XCTAssertEqual(unused.assets.count, 1)
        let project = ProjectFile(audioURL: projectURL.deletingPathExtension(), images: unused, settings: SceneSettings(), projectURL: projectURL)
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(project))
        try decoded.validate(); XCTAssertEqual(decoded.version, 4); XCTAssertEqual(decoded.images, unused)
        let existingID = images.register(url: replacement, projectURL: projectURL)
        let merged = try images.replacingAsset(id: id, url: replacement, projectURL: projectURL)
        XCTAssertEqual(merged.assets.count, 1); XCTAssertTrue(merged.clips.allSatisfy { $0.assetID == existingID })
    }
    func testLayerCompositionAlphaAndIntervals() throws {
        func image(_ color: CGColor) -> CGImage {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); return context.makeImage()!
        }
        let red = ImageRenderLayer(clip: ImageClip(assetID: UUID(), start: 0, end: 1, automaticAnimation: .off), image: image(CGColor(red: 1, green: 0, blue: 0, alpha: 1)))
        let blue = ImageRenderLayer(clip: ImageClip(assetID: UUID(), start: 0, end: 1, automaticAnimation: .off), image: image(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5)))
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        SceneRenderer.draw(in: context, size: CGSize(width: 8, height: 8), images: [red, blue], features: nil, settings: SceneSettings(spectrum: false), time: 0.5)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Double(pixels[0]), 127, accuracy: 3); XCTAssertEqual(Double(pixels[2]), 128, accuracy: 3)
        let (images, _) = try sample()
        XCTAssertTrue(images.active(at: 0.999).isEmpty); XCTAssertEqual(images.active(at: 1).count, 1); XCTAssertTrue(images.active(at: 3).isEmpty)
    }
}
