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

    @MainActor func testEditorLayoutKeepsBothModesAboveFullWidthTimeline() throws {
        let app = NSApplication.shared
        let suite = "MVStudioLayout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(storage: ProjectStorage(defaults: defaults), timelineDisplaySettings: TimelineDisplaySettings(defaults: defaults))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
        defer {
            delegate.window.close()
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
        }
        let window = try XCTUnwrap(delegate.window)
        let content = try XCTUnwrap(window.contentView)
        let editor = delegate.placementEditor
        func findPreview(in view: NSView) -> PreviewView? {
            if let preview = view as? PreviewView { return preview }
            return view.subviews.lazy.compactMap { findPreview(in: $0) }.first
        }
        let preview = try XCTUnwrap(findPreview(in: content))
        window.setContentSize(window.contentMinSize)
        for imageMode in [false, true] {
            editor.restoreMode(imageMode)
            content.layoutSubtreeIfNeeded()
            let previewFrame = content.convert(preview.bounds, from: preview)
            let inspectorFrame = content.convert(editor.inspector.bounds, from: editor.inspector)
            let timelineFrame = content.convert(editor.timeline.bounds, from: editor.timeline)
            let settings = imageMode ? editor.images.view : editor.lyrics.view
            let settingsFrame = content.convert(settings.bounds, from: settings)
            XCTAssertEqual(previewFrame.maxY, inspectorFrame.maxY, accuracy: 1)
            XCTAssertLessThan(previewFrame.maxX, inspectorFrame.minX)
            XCTAssertLessThan(timelineFrame.maxY, min(previewFrame.minY, inspectorFrame.minY))
            XCTAssertEqual(timelineFrame.minX, previewFrame.minX, accuracy: 1)
            XCTAssertEqual(timelineFrame.maxX, inspectorFrame.maxX, accuracy: 1)
            XCTAssertGreaterThan(previewFrame.height, 150)
            XCTAssertTrue(inspectorFrame.insetBy(dx: -1, dy: -1).contains(settingsFrame))
            XCTAssertTrue(content.bounds.contains(timelineFrame.union(previewFrame).union(inspectorFrame)))

        }
    }
}
