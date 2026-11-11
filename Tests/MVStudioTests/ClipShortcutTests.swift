import AppKit
import XCTest
@testable import MVStudio

final class ClipShortcutTests: XCTestCase {
    @MainActor func testLyricCutPasteAndDuplicate() throws {
        _ = NSApplication.shared
        let editor = PlacementEditor()
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        window.clipEditor = editor
        defer { window.close() }

        let first = LyricClip(start: 0, end: 1.25, text: "前")
        let source = LyricClip(start: first.end, end: 2.5, text: "歌詞", predecessorID: first.id)
        let next = LyricClip(start: source.end, end: 3.75, text: "後", predecessorID: source.id)
        editor.duration = 10
        editor.lyrics.load(LyricsTrack(clips: [first, source, next]))
        editor.setAvailable(hasAudio: true, isBusy: false)
        editor.timeline.onSelect?(source.id)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        var commits = 0
        var errors = [String]()
        editor.lyrics.onChange = { _ in commits += 1 }
        editor.onError = { errors.append($0) }
        editor.editClip(.copy, pasteboard: pasteboard)
        XCTAssertEqual(commits, 0)
        editor.editClip(.duplicate, pasteboard: pasteboard)
        XCTAssertEqual(editor.lyrics.track.clips, [first, source, next])
        XCTAssertEqual(errors.count, 1)
        editor.editClip(.cut, pasteboard: pasteboard)
        XCTAssertEqual(editor.lyrics.track.clips.map(\.id), [first.id, next.id])
        XCTAssertNil(editor.lyrics.track.clips.last?.predecessorID)

        editor.currentTime = 4.13
        editor.editClip(.paste, pasteboard: pasteboard)
        let pasted = try XCTUnwrap(editor.lyrics.track.clips.last)
        XCTAssertEqual(pasted.start, 4.13)
        XCTAssertEqual(pasted.end - pasted.start, 1.25, accuracy: 1e-9)
        XCTAssertEqual(pasted.text, source.text)
        XCTAssertNotEqual(pasted.id, source.id)
        XCTAssertNil(pasted.predecessorID)
        XCTAssertEqual(editor.timeline.selectedID, pasted.id)

        XCTAssertTrue(window.makeFirstResponder(editor.timeline))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        XCTAssertTrue(window.performKeyEquivalent(with: key))
        let duplicate = try XCTUnwrap(editor.lyrics.track.clips.last)
        XCTAssertEqual(duplicate.start, pasted.end)
        XCTAssertEqual(duplicate.text, source.text)
        XCTAssertEqual(commits, 3)
        editor.currentTime = 9.5
        editor.editClip(.paste, pasteboard: pasteboard)
        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(commits, 3)

        editor.timeline.frame = NSRect(x: 0, y: 0, width: 800, height: 112)
        editor.timeline.onSelect?(first.id)
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: editor.timeline.convert(NSPoint(x: editor.timeline.x(at: duplicate.start + 0.3), y: 58), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(editor.timeline.menu(for: rightClick))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["切り取り", "コピー", "貼り付け", "複製", "削除"])
        XCTAssertEqual(editor.timeline.selectedID, duplicate.id)
        XCTAssertEqual(editor.currentTime, 9.5)
        let duplicateItem = try XCTUnwrap(menu.item(withTitle: "複製"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(duplicateItem.action), to: duplicateItem.target, from: duplicateItem))
        XCTAssertEqual(editor.lyrics.track.clips.last?.start, duplicate.end)
        XCTAssertEqual(commits, 4)

        editor.timeline.keyDown(with: try deleteEvent(keyCode: 117, windowNumber: window.windowNumber))
        XCTAssertEqual(editor.lyrics.track.clips.last?.id, duplicate.id)
        XCTAssertNil(editor.timeline.selectedID)
        XCTAssertEqual(commits, 5)
    }

    @MainActor func testImagePasteUsesDestinationLayerAndPreservesAnimation() throws {
        _ = NSApplication.shared
        let editor = PlacementEditor()
        _ = editor.view
        editor.duration = 10
        editor.restoreTab(.visuals)
        editor.setAvailable(hasAudio: true, isBusy: false)
        let project = URL(fileURLWithPath: "/tmp/mv-clip-source/project.mvproject")
        let url = project.deletingLastPathComponent().appendingPathComponent("image.png")
        var track = VisualTrack()
        let assetID = track.register(url: url, projectURL: project)
        var source = VisualClip(assetID: assetID, start: 1, end: 3)
        source.effects = ImageEffects(blur: .init(radius: 12))
        _ = source.setKey(.rotation, at: 0.5, value: 15)
        _ = source.setKey(.rotation, at: 2, value: 60)
        track = try track.inserting(source, slot: 1, duration: 10)
        editor.visuals.load(track, projectURL: project)
        editor.timeline.onImageSelect?(source.id, 1)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        editor.editClip(.copy, pasteboard: pasteboard)
        editor.editClip(.duplicate, pasteboard: pasteboard)
        let duplicate = try XCTUnwrap(editor.visuals.track.layers.first?.clips.last)
        XCTAssertEqual(duplicate.start, source.end)
        XCTAssertEqual(duplicate.assetID, source.assetID)
        XCTAssertNotEqual(duplicate.id, source.id)

        editor.restoreTab(.lyrics)
        XCTAssertFalse(editor.canEditClip(.paste, pasteboard: pasteboard))
        editor.restoreTab(.visuals)
        let destination = URL(fileURLWithPath: "/tmp/mv-clip-destination/project.mvproject")
        editor.visuals.load(VisualTrack(), projectURL: destination)
        editor.timeline.onImageSelect?(nil, 3)
        editor.currentTime = 6
        editor.editClip(.paste, pasteboard: pasteboard)
        let pasted = try XCTUnwrap(editor.visuals.track.clips.first)
        XCTAssertEqual(editor.visuals.track.slot(of: pasted.id), 3)
        XCTAssertEqual(pasted.start, 6)
        XCTAssertEqual(pasted.end, 8)
        XCTAssertEqual(pasted.effects, source.effects)
        XCTAssertEqual(pasted.curve(.rotation)?.keys.map(\.time), [-0.5, 1])
        XCTAssertEqual(pasted.curve(.rotation)?.keys.map(\.value), [15, 60])
        XCTAssertNotEqual(pasted.curve(.rotation)?.keys.map(\.id), source.curve(.rotation)?.keys.map(\.id))
        XCTAssertEqual(editor.visuals.track.asset(pasted.assetID)?.reference.resolve(projectURL: destination), url)

        editor.timeline.revealAutomation(in: 3)
        editor.timeline.selectGraph(.rotation, key: pasted.curve(.rotation)?.keys.last?.id)
        editor.timeline.keyDown(with: try deleteEvent(keyCode: 51))
        XCTAssertEqual(editor.visuals.track.clip(pasted.id)?.curve(.rotation)?.keys.count, 1)
        editor.timeline.keyDown(with: try deleteEvent(keyCode: 51))
        XCTAssertTrue(editor.visuals.track.clips.isEmpty)
        XCTAssertNotNil(editor.visuals.track.asset(pasted.assetID))
    }

    private func deleteEvent(keyCode: UInt16, windowNumber: Int = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: windowNumber, context: nil, characters: "\u{7f}",
                                       charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: keyCode))
    }
}
