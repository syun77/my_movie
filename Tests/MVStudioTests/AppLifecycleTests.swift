import AppKit
import XCTest
@testable import MVStudio

final class AppLifecycleTests: XCTestCase {
    @MainActor func testCloseWindowThenCheckApplicationTermination() throws {
        let app = NSApplication.shared
        let suite = "MVStudioLifecycle." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var delegate: AppDelegate? = AppDelegate(storage: ProjectStorage(defaults: defaults))
        delegate!.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
        weak var retainedWindow = delegate!.window
        XCTAssertFalse(delegate!.window.isReleasedWhenClosed)
        XCTAssertTrue(delegate!.windowShouldClose(delegate!.window))
        autoreleasepool { delegate!.window.close() }
        XCTAssertNotNil(retainedWindow)
        XCTAssertFalse(delegate!.window.isVisible)
        XCTAssertEqual(delegate!.applicationShouldTerminate(app), .terminateNow)
        delegate!.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
        delegate = nil
        retainedWindow = nil
    }

    @MainActor func testEditorLayoutKeepsAllTabsAboveFullWidthTimeline() throws {
        let app = NSApplication.shared
        let suite = "MVStudioLayout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let displaySettings = TimelineDisplaySettings(defaults: defaults)
        XCTAssertEqual(displaySettings.snapDivision, .sixteenth)
        displaySettings.snapDivision = .half
        let delegate = AppDelegate(storage: ProjectStorage(defaults: defaults), timelineDisplaySettings: displaySettings)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
        defer {
            delegate.window.close()
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
        }
        let window = try XCTUnwrap(delegate.window)
        let content = try XCTUnwrap(window.contentView)
        let editor = delegate.placementEditor
        let snap = try XCTUnwrap(editor.view.subviews.flatMap(\.subviews).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(snap.itemArray.map(\.tag), [1, 2, 4, 8, 16])
        XCTAssertEqual(snap.selectedTag(), 2)
        snap.selectItem(withTag: 1)
        XCTAssertTrue(snap.sendAction(snap.action, to: snap.target))
        XCTAssertEqual(displaySettings.snapDivision, .whole)
        XCTAssertEqual(editor.lyrics.snapGrid.step, 2)
        XCTAssertEqual(editor.visuals.snapGrid.step, 2)
        XCTAssertEqual(editor.timeline.snapGrid.step, 2)
        func findPreview(in view: NSView) -> PreviewView? {
            if let preview = view as? PreviewView { return preview }
            return view.subviews.lazy.compactMap { findPreview(in: $0) }.first
        }
        let preview = try XCTUnwrap(findPreview(in: content))
        window.setContentSize(window.contentMinSize)
        for (tab, settings) in [(PlacementEditor.Tab.lyrics, editor.lyrics.view),
                                (.visuals, editor.visuals.view), (.spectrum, editor.spectrum.view)] {
            editor.restoreTab(tab)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
            settings.cacheDisplay(in: settings.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/my_movie-knob-\(tab).png"))
            for field in DragValueField.fields(in: settings) where !field.isHiddenOrHasHiddenAncestor {
                let rect = settings.convert(field.bounds, from: field)
                XCTAssertGreaterThanOrEqual(rect.minX, -1)
                XCTAssertLessThanOrEqual(rect.maxX, settings.bounds.width + 1)
                XCTAssertGreaterThanOrEqual(field.bounds.width, 70)
            }
            let previewFrame = content.convert(preview.bounds, from: preview)
            let inspectorFrame = content.convert(editor.inspector.bounds, from: editor.inspector)
            let timelineFrame = content.convert(editor.timeline.bounds, from: editor.timeline)
            let scroll = try XCTUnwrap(settings.enclosingScrollView)
            let settingsFrame = content.convert(scroll.bounds, from: scroll)
            XCTAssertEqual(previewFrame.maxY, inspectorFrame.maxY, accuracy: 1)
            XCTAssertLessThan(previewFrame.maxX, inspectorFrame.minX)
            XCTAssertLessThan(timelineFrame.maxY, min(previewFrame.minY, inspectorFrame.minY))
            XCTAssertEqual(timelineFrame.minX, previewFrame.minX, accuracy: 1)
            XCTAssertEqual(timelineFrame.maxX, inspectorFrame.maxX, accuracy: 1)
            XCTAssertGreaterThan(previewFrame.height, 150)
            XCTAssertTrue(inspectorFrame.insetBy(dx: -1, dy: -1).contains(settingsFrame))
            XCTAssertTrue(content.bounds.contains(timelineFrame.union(previewFrame).union(inspectorFrame)))
        }

        let divider = try XCTUnwrap(preview.superview?.superview?.subviews.compactMap { $0 as? TimelineDivider }.first)
        func dragDivider(by distance: CGFloat) throws {
            let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
            let end = NSPoint(x: start.x, y: start.y + distance)
            for (type, location) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                           timestamp: 0, windowNumber: window.windowNumber,
                                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                switch type {
                case .leftMouseDown:
                    XCTAssertTrue(content.hitTest(content.convert(location, from: nil)) === divider)
                    divider.mouseDown(with: event)
                case .leftMouseDragged: divider.mouseDragged(with: event)
                default: divider.mouseUp(with: event)
                }
            }
        }

        window.setContentSize(NSSize(width: 1000, height: 1000))
        editor.restoreTab(.visuals)
        content.layoutSubtreeIfNeeded()
        let originalPreviewHeight = preview.frame.height
        let originalTimelineHeight = editor.timeline.frame.height
        let dividerFrame = content.convert(divider.bounds, from: divider)
        XCTAssertGreaterThan(dividerFrame.minY, content.convert(editor.view.bounds, from: editor.view).maxY)
        XCTAssertLessThan(dividerFrame.maxY, content.convert(preview.bounds, from: preview).minY)

        var layoutCommits = 0
        editor.onTimelineHeightsCommit = { layoutCommits += 1 }
        try dragDivider(by: 0)
        XCTAssertNil(editor.timelineHeights.viewport)
        XCTAssertEqual(layoutCommits, 0)
        try dragDivider(by: 80)
        XCTAssertEqual(layoutCommits, 1)
        XCTAssertEqual(editor.timelineHeights.viewport, originalTimelineHeight + 80)
        XCTAssertEqual(editor.timeline.frame.height, originalTimelineHeight + 80, accuracy: 1)
        XCTAssertEqual(preview.frame.height, originalPreviewHeight - 80, accuracy: 1)

        editor.restoreTab(.spectrum)
        editor.restoreTab(.visuals)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.timeline.frame.height, originalTimelineHeight + 80, accuracy: 1)

        try dragDivider(by: -60)
        XCTAssertEqual(editor.timeline.frame.height, originalTimelineHeight + 20, accuracy: 1)

        try dragDivider(by: 1000)
        XCTAssertEqual(preview.frame.height, 100, accuracy: 1)
        XCTAssertTrue(content.bounds.contains(content.convert(editor.timeline.bounds, from: editor.timeline)))
        let imageScroll = try XCTUnwrap(editor.visuals.view.enclosingScrollView)
        XCTAssertGreaterThan(editor.visuals.view.frame.height, imageScroll.documentVisibleRect.height)
        let scrolled = imageScroll.contentView
        scrolled.scroll(to: NSPoint(x: 0, y: 40))
        XCTAssertGreaterThan(scrolled.bounds.minY, 0)
        editor.restoreTab(.spectrum)
        editor.restoreTab(.visuals)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrolled.bounds.minY, 0, accuracy: 1)

        window.setContentSize(window.contentMinSize)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(preview.frame.height, 99)
        XCTAssertTrue(content.bounds.contains(content.convert(editor.inspector.bounds, from: editor.inspector)))
        try dragDivider(by: -1000)
        XCTAssertEqual(editor.timeline.frame.height, 112, accuracy: 1)

        var savedHeights = TimelineHeights()
        savedHeights.viewport = 245
        savedHeights[.visual(2)] = 110
        editor.restoreTimelineHeights(savedHeights)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.timeline.frame.height, 245, accuracy: 1)
        XCTAssertEqual(editor.timeline.heights[.visual(2)], 110)
        editor.restoreTimelineHeights(TimelineHeights())
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.timeline.frame.height, originalTimelineHeight, accuracy: 1)
        XCTAssertEqual(editor.timeline.heights[.visual(2)], 46)
        XCTAssertEqual(layoutCommits, 4, "復元時は保存通知を送らない")
    }
}
