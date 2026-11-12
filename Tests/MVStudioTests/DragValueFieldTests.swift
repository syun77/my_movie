import AppKit
import XCTest
@testable import MVStudio

final class DragValueFieldTests: XCTestCase {
    @MainActor func testAutomationMenuCoversNumberAndRoutesWhileEditing() throws {
        _ = NSApplication.shared
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = DragValueField(frame: NSRect(x: 10, y: 10, width: 120, height: 26))
        window.contentView?.addSubview(field)
        field.stringValue = "100"
        var created = 0, removed = 0
        field.onCreateAutomation = { created += 1; field.hasAutomation = true }
        field.onRemoveAutomation = { removed += 1; field.hasAutomation = false }
        defer { field.onCreateAutomation = nil; field.onRemoveAutomation = nil }
        func event(x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: .rightMouseDown,
                location: field.convert(NSPoint(x: x, y: 13), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        XCTAssertNotNil(field.menu(for: event(x: 11)))
        let create = try XCTUnwrap(field.menu(for: event(x: 80))?.items.first)
        XCTAssertEqual(create.title, "オートメーションを作成")
        XCTAssertNil(window.editingAutomationField(for: event(x: 80)))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(create.action), to: create.target, from: create))
        XCTAssertEqual(created, 1)
        field.selectText(nil)
        XCTAssertNotNil(field.currentEditor())
        XCTAssertTrue(window.editingAutomationField(for: event(x: 80)) === field)
        XCTAssertNil(window.editingAutomationField(for: event(x: 140)))
        let remove = try XCTUnwrap(field.menu(for: event(x: 80))?.items.first)
        XCTAssertEqual(remove.title, "オートメーションを削除")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(remove.action), to: remove.target, from: remove))
        XCTAssertEqual(removed, 1)
        window.makeFirstResponder(nil)
        field.isEnabled = false
        XCTAssertNil(field.menu(for: event(x: 80)))
        field.isEnabled = true
        field.onCreateAutomation = nil
        field.onRemoveAutomation = nil
        XCTAssertNil(field.menu(for: event(x: 80)))
    }

    @MainActor func testVerticalHorizontalFineDragAndCancellation() throws {
        _ = NSApplication.shared
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = DragValueField(frame: NSRect(x: 10, y: 10, width: 120, height: 26))
        window.contentView?.addSubview(field)
        var value = 50.0
        var commits = 0
        var preview: Double?
        field.stringValue = "50"
        field.bindNumber(current: { value }, initial: { 50 }, preview: { preview = $0 },
                         commit: { value = $0; commits += 1 })
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double,
                   shift: Bool = false, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                              modifierFlags: shift ? [.shift] : [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil,
                              eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        field.mouseDown(with: event(.leftMouseDown, 20, 20))
        field.mouseDragged(with: event(.leftMouseDragged, 21, 40))
        XCTAssertEqual(preview, 70)
        XCTAssertEqual(value, 50)
        field.mouseUp(with: event(.leftMouseUp, 21, 45))
        XCTAssertEqual(value, 75)
        XCTAssertEqual(commits, 1)
        field.mouseDown(with: event(.leftMouseDown, 20, 40))
        field.mouseDragged(with: event(.leftMouseDragged, 20, 20))
        XCTAssertEqual(preview, 55)
        XCTAssertTrue(field.cancelNumberDrag())
        XCTAssertEqual(field.stringValue, "75")
        XCTAssertNil(preview)
        field.mouseUp(with: event(.leftMouseUp, 20, 20))
        XCTAssertEqual(commits, 1)
        field.mouseDown(with: event(.leftMouseDown, 20, 20))
        field.mouseDragged(with: event(.leftMouseDragged, 40, 21, shift: true))
        XCTAssertEqual(preview, 77)
        field.mouseUp(with: event(.leftMouseUp, 40, 21, shift: true))
        XCTAssertEqual(value, 77)
        XCTAssertTrue(field.resetValue())
        XCTAssertEqual(value, 50)
        field.mouseDown(with: event(.leftMouseDown, 50, 20, clicks: 2))
        XCTAssertNotNil(field.currentEditor())
        window.makeFirstResponder(nil)
        let image = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: image)
        try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-knob.png"))
    }
}
