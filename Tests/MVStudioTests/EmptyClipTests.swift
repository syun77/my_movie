import AppKit
import XCTest
@testable import MVStudio

final class EmptyClipTests: XCTestCase {
    func testPlacementPersistenceValidationAndImageAssignment() throws {
        let grid = TimelineSnapGrid(bpm: 120, origin: 0)
        let added = try VisualTrack().addingEmpty(at: 1.03, slot: 3, duration: 10, grid: grid)
        XCTAssertEqual(added.clip.effects?.solidBackground, .init())
        XCTAssertNil(added.clip.assetID)
        XCTAssertEqual(added.clip.start, grid.nearest(1.03))
        XCTAssertEqual(added.track.assets.count, 0)
        XCTAssertThrowsError(try added.track.addingEmpty(at: 1.5, slot: 3, duration: 10, grid: grid))
        let restored = try JSONDecoder().decode(VisualTrack.self, from: JSONEncoder().encode(added.track))
        XCTAssertEqual(restored, added.track)
        try restored.validate(duration: 10)
        var clip = added.clip
        clip.content = .video(sourceIn: 0)
        XCTAssertThrowsError(try restored.updating(clip, slot: 3, duration: 10))
        clip = added.clip
        clip.assetID = UUID()
        XCTAssertThrowsError(try restored.updating(clip, slot: 3, duration: 10))
        clip = added.clip
        _ = clip.setKey(.rotation, at: 0.5, value: 30)
        var track = restored
        clip.assetID = track.register(url: URL(fileURLWithPath: "/tmp/assigned.png"), projectURL: URL(fileURLWithPath: "/tmp/song.mvproject"))
        track = try track.updating(clip, slot: 3, duration: 10)
        XCTAssertEqual(track.clip(clip.id)?.curves, clip.curves)
        XCTAssertEqual(track.clip(clip.id)?.start, added.clip.start)
    }

    @MainActor
    func testSolidBackgroundEditorAndValidation() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2)
        editor.load(clip, editable: true)
        var commits = 0
        editor.onCommit = { effects in
            commits += 1
            clip.effects = effects
            editor.load(clip, editable: true)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
        let add = try XCTUnwrap(views(editor).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.item(withTitle: "単色背景"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(clip.effects?.solidBackground, .init())
        let color = try XCTUnwrap(views(editor).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.backgroundColor" })
        color.color = .red
        XCTAssertTrue(color.sendAction(color.action, to: color.target))
        XCTAssertEqual(clip.effects?.solidBackground?.color, RGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.effects?.solidBackground?.color.red = .nan
        XCTAssertEqual(clip.effects?.isValid, false)
    }

    @MainActor
    func testBackgroundColorPanelWithSnowPersistsAcrossSelection() throws {
        _ = NSApplication.shared
        let editor = VisualEditor()
        _ = editor.view
        editor.duration = 10
        editor.setAvailable(true)
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        editor.timeline = timeline
        var clip = VisualClip(assetID: nil, start: 0, end: 3, audioModulations: [:],
                              effects: ImageEffects(solidBackground: .init(), snow: .init(seed: 42)))
        let other = VisualClip(assetID: nil, start: 4, end: 6)
        let track = try VisualTrack().inserting(clip, slot: 3, duration: 10).inserting(other, slot: 3, duration: 10)
        editor.load(track, projectURL: URL(fileURLWithPath: "/tmp/color-panel.mvproject"))
        timeline.onImageSelect?(clip.id, 3)
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
        let effects = try XCTUnwrap(views(editor.view).compactMap { $0 as? ImageEffectsEditor }.first)
        let picker = try XCTUnwrap(views(effects).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("単色背景") && !$0.pullsDown })
        picker.selectItem(withTitle: "単色背景")
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        let well = try XCTUnwrap(views(effects).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.backgroundColor" })
        var changed: VisualTrack?
        editor.onChange = { changed = $0 }
        let panel = NSColorPanel.shared
        defer { well.deactivate(); panel.orderOut(nil) }
        well.activate(true)
        panel.color = .red
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(RGBColor(well.color), RGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.solidBackground?.color, RGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.snow, clip.effects?.snow)
        XCTAssertEqual(changed?.clip(clip.id)?.effects?.solidBackground?.color, RGBColor(red: 1, green: 0, blue: 0))
        timeline.onImageSelect?(other.id, 3)
        XCTAssertNil(editor.track.clip(other.id)?.effects, "クリップ切替時に色変更を別の配置へ適用しない")
        timeline.onImageSelect?(clip.id, 3)
        XCTAssertEqual(RGBColor(well.color), RGBColor(red: 1, green: 0, blue: 0))
        picker.selectItem(withTitle: "単色背景")
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        well.activate(true)
        panel.color = .blue
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.solidBackground?.color, RGBColor(red: 0, green: 0, blue: 1))
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.snow, clip.effects?.snow)
        clip = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
    }

    func testEmptyClipRenderingAndExportValidation() async throws {
        let track = try VisualTrack().addingEmpty(at: 0, slot: 1, duration: 10, grid: TimelineSnapGrid()).track
        let url = URL(fileURLWithPath: "/tmp/empty-song.mvproject")
        let provider = VisualFrameProvider()
        try await provider.validateUsed(track: track, projectURL: url, cancellation: ExportCancellation())
        let layers = try await provider.layers(track: track, projectURL: url, time: 0.5, allowMissingImages: false)
        XCTAssertEqual(layers.count, 1, "透明画像を通じて追加演出も評価する")
        XCTAssertNil(layers.first?.clip.assetID)
    }

    @MainActor
    func testCopyPasteAndAssignImagePreserveAutomation() async throws {
        _ = NSApplication.shared
        let editor = PlacementEditor()
        _ = editor.view
        editor.duration = 10
        editor.restoreTab(.visuals)
        editor.setAvailable(hasAudio: true, isBusy: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("song.mvproject")
        var clip = VisualClip(assetID: nil, start: 1, end: 3)
        _ = clip.setKey(.rotation, at: 0.5, value: 30)
        clip.effects = ImageEffects(blur: .init(radius: 12))
        let track = try VisualTrack().inserting(clip, slot: 3, duration: 10)
        editor.visuals.load(track, projectURL: project)
        editor.timeline.onImageSelect?(clip.id, 3)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        editor.editClip(.copy, pasteboard: pasteboard)
        editor.currentTime = 5
        editor.editClip(.paste, pasteboard: pasteboard)
        let pasted = try XCTUnwrap(editor.visuals.track.layers[2].clips.last)
        XCTAssertNil(pasted.assetID)
        XCTAssertEqual(pasted.start, 5)
        XCTAssertEqual(pasted.effects, clip.effects)
        XCTAssertEqual(pasted.curves.first?.keys.first?.value, 30)
        XCTAssertNotEqual(pasted.curves.first?.keys.first?.id, clip.curves.first?.keys.first?.id)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = folder.appendingPathComponent("assigned.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let assigned = expectation(description: "画像設定を確定")
        editor.visuals.onChange = { _ in assigned.fulfill() }
        editor.visuals.importFile(url, replacingClip: pasted.id)
        await fulfillment(of: [assigned], timeout: 10)
        let result = try XCTUnwrap(editor.visuals.track.clip(pasted.id))
        XCTAssertNotNil(result.assetID)
        XCTAssertEqual(result.curves, pasted.curves)
        XCTAssertEqual(result.effects, pasted.effects)
        XCTAssertEqual(result.start, pasted.start)
        XCTAssertEqual(result.end, pasted.end)
    }

    @MainActor
    func testEmptyAreaContextMenuCreatesClipWithoutSeeking() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let editor = VisualEditor()
        _ = editor.view
        editor.timeline = timeline
        editor.duration = 10
        editor.load(VisualTrack(), projectURL: URL(fileURLWithPath: "/tmp/empty-song.mvproject"))
        editor.setAvailable(true)
        timeline.visualMode = true
        timeline.duration = 10
        timeline.currentTime = 0.5
        var commits = 0
        editor.onChange = { _ in commits += 1 }
        func menu(time: Double, y: Double) throws -> NSMenu? {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                location: timeline.convert(NSPoint(x: timeline.x(at: time), y: y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            return timeline.menu(for: event)
        }
        let first = try XCTUnwrap(menu(time: 1, y: 65)?.item(withTitle: "空のクリップを作成"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(first.action), to: first.target, from: first))
        XCTAssertEqual(commits, 1)
        let clip = try XCTUnwrap(editor.track.clips.first)
        XCTAssertEqual(editor.track.slot(of: clip.id), 3)
        XCTAssertNil(clip.assetID)
        XCTAssertEqual(timeline.currentTime, 0.5)
        XCTAssertNil(try menu(time: 1.5, y: 65)?.item(withTitle: "空のクリップを作成"))
        timeline.revealAutomation(in: 3)
        let laneItem = try XCTUnwrap(menu(time: 5, y: 120)?.item(withTitle: "空のクリップを作成"))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(laneItem.action), to: laneItem.target, from: laneItem))
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(editor.track.layers[2].clips.count, 2)
        timeline.isEnabled = false
        XCTAssertNil(try menu(time: 8, y: 120))
    }
}
