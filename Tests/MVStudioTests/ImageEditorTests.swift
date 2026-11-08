import AppKit
import ImageIO
import XCTest
@testable import MVStudio

final class ImageEditorTests: XCTestCase {
    private func png(at url: URL, red: CGFloat) throws {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    @MainActor private func waitForImport(_ editor: ImageEditor) async throws {
        for _ in 0..<250 {
            if !editor.isProcessing { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("画像読込が完了しません")
    }
    @MainActor func testImportsReplacementFailureAndProjectSwitchAreAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("song.wav.mvproject")
        let a = directory.appendingPathComponent("a.png"), b = directory.appendingPathComponent("b.png")
        try png(at: a, red: 1); try png(at: b, red: 0)
        let editor = ImageEditor(); _ = editor.view
        editor.load(ImageTrack(), projectURL: project); editor.duration = 10; editor.setAvailable(true)
        var saves = 0; editor.onChange = { _ in saves += 1 }
        editor.importFile(a, placement: (2, 1.04)); try await waitForImport(editor)
        XCTAssertEqual(editor.track.clips.count, 1); XCTAssertEqual(editor.track.clips[0].start, 1); XCTAssertEqual(saves, 1)
        let original = editor.track
        editor.importFile(b, placement: (2, 1)); try await waitForImport(editor)
        XCTAssertEqual(editor.track, original); XCTAssertEqual(saves, 1, "配置失敗で素材だけを登録しない")
        let id = original.assets[0].id
        editor.importFile(b, replacingAsset: id); try await waitForImport(editor)
        XCTAssertEqual(editor.track.clips, original.clips)
        XCTAssertEqual(editor.track.asset(id)?.reference.resolve(projectURL: project), b)
        try FileManager.default.removeItem(at: b)
        let missingTrack = editor.track
        await XCTAssertThrowsErrorAsync { try await editor.store.validateUsed(track: missingTrack, projectURL: project) }
        editor.importFile(a, replacingAsset: id); try await waitForImport(editor)
        try await editor.store.validateUsed(track: editor.track, projectURL: project)
        editor.importFile(a)
        editor.load(ImageTrack(), projectURL: directory.appendingPathComponent("different.wav.mvproject"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(editor.track.assets.isEmpty)
        let preserved = editor.track
        editor.importFile(directory.appendingPathComponent("missing.png")); try await waitForImport(editor)
        XCTAssertEqual(editor.track, preserved)
    }
    @MainActor func testPlacementTabsKeepSharedTimeAndRejectInvalidInput() throws {
        _ = NSApplication.shared
        let editor = PlacementEditor(); _ = editor.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { window.close() }
        editor.currentTime = 4; editor.duration = 10; editor.visibleSpan = 7.5
        var track = ImageTrack()
        let project = URL(fileURLWithPath: "/tmp/song.wav.mvproject")
        let asset = track.register(url: URL(fileURLWithPath: "/tmp/sample.png"), projectURL: project)
        let added = try track.adding(assetID: asset, at: 1, slot: 1, duration: 10, grid: TimelineSnapGrid())
        editor.images.load(added.track, projectURL: project); editor.setAvailable(true)
        func find(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0, id) }.first
        }
        let tabs = try XCTUnwrap(find(editor.view, "placement.mode") as? NSSegmentedControl)
        tabs.selectedSegment = 1; editor.perform(NSSelectorFromString("changePlacementMode"))
        XCTAssertTrue(editor.imageMode); XCTAssertEqual(editor.currentTime, 4); XCTAssertEqual(editor.timeline.visibleSpan, 7.5)
        editor.view.layoutSubtreeIfNeeded()
        let timeline = editor.timeline
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: timeline.convert(NSPoint(x: timeline.x(at: 2), y: 160), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        timeline.mouseDown(with: event); timeline.cancelDrag()
        let start = try XCTUnwrap(find(editor.view, "images.start") as? NSTextField)
        start.stringValue = "abc"; editor.images.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: start))
        tabs.selectedSegment = 0; editor.perform(NSSelectorFromString("changePlacementMode"))
        XCTAssertTrue(editor.imageMode); XCTAssertEqual(tabs.selectedSegment, 1)
        start.stringValue = "1"; editor.images.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: start))
        editor.snapGrid = TimelineSnapGrid(bpm: 137, origin: 0.04)
        XCTAssertTrue(editor.images.finishEditing())
        XCTAssertEqual(editor.images.track.clips[0].start, 1, "BPM変更だけでは既存配置を動かさない")
        tabs.selectedSegment = 0; editor.perform(NSSelectorFromString("changePlacementMode"))
        XCTAssertFalse(editor.imageMode); XCTAssertEqual(editor.currentTime, 4)
        editor.restoreMode(true)
        editor.timeline.track = LyricsTrack(clips: [LyricClip(start: 1, end: 3, text: "ゴースト：歌詞のタイミング")])
        editor.view.layoutSubtreeIfNeeded()
        if let bitmap = editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds) {
            editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-images-editor.png"))
        }
        let manager = ImageAssetManager(editor: editor.images)
        manager.window!.contentView!.layoutSubtreeIfNeeded()
        let content = manager.window!.contentView!
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-images-manager.png"))
        }
        manager.window!.close()
    }
    @MainActor func testDragBetweenLayersPreservesTimeRejectsCollisionsAndCancels() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210)); window.contentView = view
        view.imageMode = true; view.isEnabled = true; view.duration = 20
        let project = URL(fileURLWithPath: "/tmp/song.wav.mvproject")
        var track = ImageTrack(); let id = track.register(url: URL(fileURLWithPath: "/tmp/image.png"), projectURL: project)
        let first = try track.adding(assetID: id, at: 1, slot: 1, duration: 20, grid: TimelineSnapGrid())
        track = try first.track.adding(assetID: id, at: 1, slot: 2, duration: 20, grid: TimelineSnapGrid()).track
        view.images = track
        var commits = 0; var preview: ImageTrack?
        view.onImageCommit = { value, _ in commits += 1; view.images = value }
        view.onImagePreview = { preview = $0 }
        func event(_ type: NSEvent.EventType, _ time: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.x(at: time), y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 2, 160))
        view.mouseDragged(with: event(.leftMouseDragged, 5, 68))
        XCTAssertEqual(preview?.slot(of: first.clip.id), 3)
        XCTAssertEqual(preview?.clip(first.clip.id), first.clip, "段移動は横ずれがあっても時間と演出を保持")
        XCTAssertEqual(commits, 0)
        view.mouseUp(with: event(.leftMouseUp, 5, 68))
        XCTAssertEqual(commits, 1); XCTAssertEqual(view.images.slot(of: first.clip.id), 3)
        view.mouseDown(with: event(.leftMouseDown, 2, 68))
        view.mouseDragged(with: event(.leftMouseDragged, 2, 160))
        XCTAssertEqual(preview?.slot(of: first.clip.id), 1)
        view.mouseDragged(with: event(.leftMouseDragged, 2, 115))
        XCTAssertEqual(preview, view.images, "有効な仮位置のあとでも衝突先では元に戻す")
        view.mouseUp(with: event(.leftMouseUp, 2, 115))
        XCTAssertEqual(commits, 1); XCTAssertEqual(view.images.slot(of: first.clip.id), 3)
        view.mouseDown(with: event(.leftMouseDown, 2, 68))
        view.mouseDragged(with: event(.leftMouseDragged, 2, 160))
        view.cancelDrag()
        view.mouseUp(with: event(.leftMouseUp, 2, 160))
        XCTAssertEqual(commits, 1); XCTAssertEqual(view.images.slot(of: first.clip.id), 3)
        view.mouseDown(with: event(.leftMouseDown, 2, 68))
        view.mouseDragged(with: event(.leftMouseDragged, 2, 160))
        view.mouseUp(with: event(.leftMouseUp, 2, 205))
        XCTAssertEqual(commits, 1, "最後のmouseUp位置が行外なら取り消す")
        view.mouseDown(with: event(.leftMouseDown, 1, 68))
        view.mouseDragged(with: event(.leftMouseDragged, 1.5, 160))
        view.mouseUp(with: event(.leftMouseUp, 1.5, 160))
        XCTAssertEqual(view.images.slot(of: first.clip.id), 3, "端トリムでは段を変えない")
        XCTAssertEqual(view.images.clip(first.clip.id)?.start, 1.5)
    }
    @MainActor func testTimelineGhostHitTestingImageDragAndDropCoordinates() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210)); window.contentView = view
        view.imageMode = true; view.isEnabled = true; view.duration = 20
        view.track = LyricsTrack(clips: [LyricClip(start: 0, end: 10, text: "歌詞のゴースト")])
        let project = URL(fileURLWithPath: "/tmp/song.wav.mvproject"), url = URL(fileURLWithPath: "/tmp/image.png")
        var track = ImageTrack(); let asset = track.register(url: url, projectURL: project)
        let added = try track.adding(assetID: asset, at: 1, slot: 1, duration: 20, grid: TimelineSnapGrid())
        view.images = added.track
        var lyricSelections = 0, commits = 0
        view.onSelect = { _ in lyricSelections += 1 }
        view.onImageCommit = { track, _ in commits += 1; view.images = track }
        func event(_ type: NSEvent.EventType, time: Double, y: Double = 160) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.x(at: time), y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, time: 2)); view.mouseDragged(with: event(.leftMouseDragged, time: 3))
        XCTAssertEqual(commits, 0)
        view.mouseUp(with: event(.leftMouseUp, time: 3))
        XCTAssertEqual(commits, 1); XCTAssertEqual(view.images.clips[0].start, 2)
        XCTAssertEqual(lyricSelections, 0); XCTAssertEqual(view.track.clips[0].start, 0)
        view.mouseDown(with: event(.leftMouseDown, time: 3)); view.mouseDragged(with: event(.leftMouseDragged, time: 4)); view.cancelDrag()
        XCTAssertEqual(commits, 1); XCTAssertEqual(view.images.clips[0].start, 2)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([url as NSURL])
        let drop = try view.fileDrop(at: NSPoint(x: view.x(at: 6.04), y: 115), pasteboard: pasteboard)
        XCTAssertEqual(drop.slot, 2); XCTAssertEqual(drop.start, 6); XCTAssertEqual(drop.end, 8)
        let dragInfo = FileDragInfo(window: window, pasteboard: pasteboard, point: view.convert(NSPoint(x: view.x(at: 6.04), y: 115), to: nil))
        var received: (URL, Int, Double)?
        view.onDropImage = { received = ($0, $1, $2) }
        XCTAssertEqual(view.draggingEntered(dragInfo), .copy)
        XCTAssertTrue(view.prepareForDragOperation(dragInfo))
        XCTAssertTrue(view.performDragOperation(dragInfo))
        view.concludeDragOperation(dragInfo)
        XCTAssertEqual(received?.0, url); XCTAssertEqual(received?.1, 2); XCTAssertEqual(received?.2, 6)
        XCTAssertThrowsError(try view.fileDrop(at: NSPoint(x: view.x(at: 3), y: 160), pasteboard: pasteboard))
        XCTAssertThrowsError(try view.fileDrop(at: NSPoint(x: 5, y: 115), pasteboard: pasteboard))
        pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL, URL(fileURLWithPath: "/tmp/two.png") as NSURL])
        XCTAssertThrowsError(try view.fileDrop(at: NSPoint(x: view.x(at: 6), y: 115), pasteboard: pasteboard))
        view.imageMode = false
        XCTAssertThrowsError(try view.fileDrop(at: NSPoint(x: view.x(at: 6), y: 115), pasteboard: pasteboard))
        view.imageMode = true
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-images-timeline.png"))
        }
    }
}

private func XCTAssertThrowsErrorAsync(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("エラーが必要です", file: file, line: line) } catch { }
}

@MainActor
private final class FileDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, pasteboard: NSPasteboard, point: NSPoint) {
        draggingDestinationWindow = window; draggingPasteboard = pasteboard; draggingLocation = point
    }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() { }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
}
