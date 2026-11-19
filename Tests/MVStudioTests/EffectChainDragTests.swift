import AppKit
import XCTest
@testable import MVStudio

@MainActor
final class EffectChainDragTests: XCTestCase {
    @MainActor private final class Fixture {
        let window: NSWindow
        let list = EffectChainList()
        var previews: [Int] = []
        var commits: [Int] = []
        var cancels = 0
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
            window.contentView = root
            root.addSubview(list)
            list.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
            list.nodes = ImageEffects(blur: .init(), snow: .init(seed: 0), colorCorrection: .init()).nodes
            list.editable = true
            list.onMove = { [weak self] _, index, preview in
                if preview { self?.previews.append(index) } else { self?.commits.append(index) }
            }
            list.onCancel = { [weak self] in self?.cancels += 1 }
        }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: list.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func down(_ x: Double = 8, _ y: Double = 10) throws { list.mouseDown(with: try event(.leftMouseDown, x, y)) }
        func move(_ x: Double, _ y: Double) throws { list.mouseDragged(with: try event(.leftMouseDragged, x, y)) }
        func up(_ x: Double, _ y: Double) throws { list.mouseUp(with: try event(.leftMouseUp, x, y)) }
        func bitmap() throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(list.bitmapImageRepForCachingDisplay(in: list.bounds))
            list.cacheDisplay(in: list.bounds, to: bitmap)
            return bitmap
        }
    }

    func testWaitingThresholdOffsetAndSelectionAreIndependent() throws {
        let fixture = Fixture(); defer { fixture.window.close() }
        let list = fixture.list
        let original = list.nodes
        list.selectedID = original.last?.id
        list.detailsOpen = false
        try fixture.down()
        XCTAssertNil(list.dragPresentation)
        try fixture.move(10, 13)
        XCTAssertNil(list.dragPresentation)
        try fixture.up(10, 13)
        XCTAssertEqual(fixture.previews, []); XCTAssertEqual(fixture.commits, []); XCTAssertEqual(fixture.cancels, 0)
        try fixture.down()
        try fixture.move(11, 14)
        let presentation = try XCTUnwrap(list.dragPresentation)
        XCTAssertEqual(presentation.id, original.first?.id)
        XCTAssertEqual(presentation.sourceRect.minY, 0)
        XCTAssertEqual(presentation.floatingRect.minY, 4)
        XCTAssertEqual(presentation.floatingRect.minX, 0)
        XCTAssertEqual(presentation.floatingRect.width, list.bounds.width)
        XCTAssertEqual(list.selectedID, original.last?.id); XCTAssertFalse(list.detailsOpen)
        XCTAssertEqual(list.nodes, original)
        try fixture.up(11, 14)
        XCTAssertNil(list.dragPresentation)
        XCTAssertEqual(fixture.commits, []); XCTAssertEqual(fixture.cancels, 1)
        try fixture.down()
        try fixture.move(13, 10)
        XCTAssertNotNil(list.dragPresentation, "Horizontal movement also starts the gesture")
        list.cancelOperation(nil)
        try fixture.up(8, 78)
        XCTAssertEqual(fixture.commits, [])
    }

    func testOutsideReentryAndFinalMouseUpDestination() throws {
        let fixture = Fixture(); defer { fixture.window.close() }
        try fixture.down()
        try fixture.move(8, 78)
        XCTAssertEqual(fixture.previews, [2])
        XCTAssertEqual(fixture.list.dragPresentation?.insertionY, 84)
        try fixture.move(-20, 40)
        XCTAssertNil(fixture.list.dragPresentation?.insertionY)
        XCTAssertNotNil(fixture.list.dragPresentation)
        XCTAssertEqual(fixture.previews, [2], "Outside movement preserves the last valid preview")
        try fixture.move(8, 15)
        XCTAssertEqual(fixture.previews, [2, 0])
        try fixture.up(8, 78)
        XCTAssertEqual(fixture.commits, [2], "The final release coordinate determines the committed destination")
        XCTAssertNil(fixture.list.dragPresentation)
        try fixture.down()
        try fixture.move(8, 78)
        try fixture.up(-20, 78)
        XCTAssertEqual(fixture.commits, [2]); XCTAssertEqual(fixture.cancels, 1)
        try fixture.down(8, 70)
        try fixture.move(8, 2)
        XCTAssertEqual(fixture.list.dragPresentation?.insertionY, 0)
        try fixture.up(8, 2)
        XCTAssertEqual(fixture.commits, [2, 0])
    }

    func testCancellationOnReloadDisableAndDetach() throws {
        let fixture = Fixture(); defer { fixture.window.close() }
        for operation in 0..<4 {
            fixture.list.editable = true
            try fixture.down(); try fixture.move(8, 78)
            switch operation {
            case 0: fixture.list.cancelOperation(nil)
            case 1: fixture.list.editable = false
            case 2:
                var nodes = fixture.list.nodes
                nodes[0].isEnabled.toggle()
                fixture.list.nodes = nodes
            default: fixture.list.removeFromSuperview()
            }
            XCTAssertNil(fixture.list.dragPresentation)
            try fixture.up(8, 78)
            XCTAssertEqual(fixture.cancels, operation + 1)
            XCTAssertEqual(fixture.commits, [])
        }
    }

    func testScrollClippingAndContextMenuDuringDrag() throws {
        let fixture = Fixture(); defer { fixture.window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        fixture.list.removeFromSuperview()
        fixture.window.contentView?.addSubview(scroll)
        scroll.documentView = fixture.list
        fixture.list.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 14))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(fixture.list.visibleRect.minY, 0)
        XCTAssertLessThan(fixture.list.visibleRect.maxY, fixture.list.bounds.maxY)
        try fixture.down(8, 38)
        try fixture.move(8, 50)
        XCTAssertNotNil(fixture.list.dragPresentation?.insertionY)
        var menus = 0
        fixture.list.menuForNode = { _ in menus += 1; return NSMenu() }
        fixture.list.rightMouseDown(with: try fixture.event(.rightMouseDown, 8, 38))
        XCTAssertEqual(menus, 0)
        try fixture.move(8, 65)
        XCTAssertNotNil(fixture.list.dragPresentation)
        XCTAssertNil(fixture.list.dragPresentation?.insertionY)
        try fixture.up(8, 65)
        XCTAssertEqual(fixture.commits, []); XCTAssertEqual(fixture.cancels, 1)
        try fixture.down(8, 38)
        XCTAssertTrue(fixture.list.cancelDrag())
        XCTAssertEqual(fixture.cancels, 1, "Cancelling a pending click does not send a preview cancellation")
    }

    func testRenderedSourceOpacityAndFloatingRowInBothAppearances() throws {
        let fixture = Fixture(); defer { fixture.window.close() }
        fixture.list.nodes[0].isEnabled = false
        fixture.list.selectedID = fixture.list.nodes.last?.id
        func maximumAlpha(_ bitmap: NSBitmapImageRep, minY: Int, maxY: Int) -> Double {
            let scale = Double(bitmap.pixelsWide) / fixture.list.bounds.width
            var alpha = 0.0
            for y in Int(Double(minY) * scale)..<Int(Double(maxY) * scale) {
                for x in 0..<bitmap.pixelsWide { alpha = max(alpha, Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)) }
            }
            return alpha
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            fixture.list.appearance = NSAppearance(named: appearance)
            let normal = try fixture.bitmap()
            try fixture.down(); try fixture.move(8, 42)
            let floating = try fixture.bitmap()
            XCTAssertEqual(maximumAlpha(floating, minY: 0, maxY: 25), maximumAlpha(normal, minY: 0, maxY: 25) * 0.3, accuracy: 0.03)
            let scale = Double(floating.pixelsWide) / fixture.list.bounds.width
            let alpha = try XCTUnwrap(floating.colorAt(x: Int(200 * scale), y: Int(42 * scale))).alphaComponent
            XCTAssertEqual(Double(alpha), 0.85, accuracy: 0.03)
            let url = URL(fileURLWithPath: "/tmp/my-movie-chain-drag-\(name).png")
            try XCTUnwrap(floating.representation(using: .png, properties: [:])).write(to: url)
            fixture.list.cancelOperation(nil)
            let restored = try fixture.bitmap()
            XCTAssertEqual(maximumAlpha(restored, minY: 0, maxY: 25), maximumAlpha(normal, minY: 0, maxY: 25), accuracy: 0.01)
        }
    }
}
