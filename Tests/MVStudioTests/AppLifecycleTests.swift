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
        delegate!.window.contentView!.layoutSubtreeIfNeeded()
        let content = delegate!.window.contentView!
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-images-app.png"))
        }
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
}
