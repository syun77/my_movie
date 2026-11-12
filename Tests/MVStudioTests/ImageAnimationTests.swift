import AppKit
import XCTest
@testable import MVStudio

final class ImageAnimationTests: XCTestCase {
    @MainActor private func automationMenu(_ field: DragValueField) -> NSMenu? {
        if field.bounds.isEmpty { field.setFrameSize(NSSize(width: 90, height: 24)) }
        let event = NSEvent.mouseEvent(with: .rightMouseDown,
            location: field.convert(NSPoint(x: 11, y: field.bounds.midY), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: field.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        return field.menu(for: event)
    }

    @MainActor private func performAutomationMenu(_ field: DragValueField, title: String) throws {
        let menu = try XCTUnwrap(automationMenu(field))
        XCTAssertEqual(menu.items.map(\.title), [title])
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private func fixture(slot: Int = 3) throws -> (VisualTrack, VisualClip) {
        var track = VisualTrack()
        let asset = track.register(url: URL(fileURLWithPath: "/tmp/animation.png"), projectURL: URL(fileURLWithPath: "/tmp/animation.mvproject"))
        let added = try track.adding(assetID: asset, at: 1, slot: slot, duration: 10, grid: TimelineSnapGrid())
        return (added.track, added.clip)
    }

    func testInterpolationPulseAndTrimmingPreserveTheCurve() throws {
        var (track, clip) = try fixture()
        clip.automaticAnimation = .beat
        let first = clip.setKey(.scale, at: 1, value: 100)
        let last = clip.setKey(.scale, at: 3, value: 140)
        XCTAssertEqual(clip.setKey(.scale, at: 3 + 1e-8, value: 140), last)
        _ = clip.setKey(.rotation, at: 1, value: 0)
        _ = clip.setKey(.rotation, at: 3, value: 360)
        let settings = SceneSettings(bpm: 120, beatOffset: 1.5, spectrum: false)
        XCTAssertEqual(clip.scale(at: 2, settings: settings, transientPulse: 0), 1.296, accuracy: 1e-9)
        XCTAssertEqual(clip.manualValue(.rotation, at: 2), 180)
        XCTAssertEqual(clip.scale(at: 1.25, settings: settings, transientPulse: 1), 1.05, accuracy: 1e-9)
        XCTAssertEqual(clip.keyTime(at: 1.01, grid: TimelineSnapGrid(bpm: 137, origin: 0.1)), 1)
        XCTAssertEqual(clip.keyTime(at: 1.04, grid: nil), 1.04)

        track = try track.updating(clip, slot: 3, duration: 10)
        let trimmed = try track.dragging(id: clip.id, part: .start, delta: 0.5, duration: 10, grid: TimelineSnapGrid())
        let shortened = try XCTUnwrap(trimmed.clip(clip.id))
        XCTAssertEqual(shortened.curve(.scale)?.keys.first?.time, -0.5)
        XCTAssertEqual(shortened.manualValue(.scale, at: 1.75), 115, accuracy: 1e-9)
        let restored = try trimmed.dragging(id: clip.id, part: .start, delta: -0.5, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(restored, track)
        var shifted = shortened
        shifted.setBaseValue(45, for: .rotation)
        XCTAssertEqual(shifted.curve(.rotation)?.keys.map(\.time), [-0.5, 1.5])
        XCTAssertEqual(shifted.curve(.rotation)?.keys.map(\.value), [45, 405])
        XCTAssertEqual(shifted.curve(.rotation)?.minimum, -135)
        XCTAssertEqual(shifted.curve(.rotation)?.maximum, 225)
        let moved = try track.dragging(id: clip.id, part: .move, delta: 1, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(moved.clips[0].manualValue(.rotation, at: 3), 180)

        clip.removeKey(first, parameter: .scale)
        clip.removeKey(last, parameter: .scale)
        XCTAssertNil(clip.curve(.scale))
        XCTAssertEqual(clip.manualValue(.scale, at: 1), 140)
    }

    @MainActor private func control<T: NSControl>(_ id: String, in view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        return view.subviews.lazy.compactMap { self.control(id, in: $0) as T? }.first
    }

    @MainActor func testTransformFieldDoubleClickAndHorizontalDrag() throws {
        _ = NSApplication.shared
        let editor = VisualEditor()
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        defer { window.close() }
        let timeline = TimelineView(frame: .zero)
        editor.timeline = timeline
        let (track, clip) = try fixture()
        editor.duration = 10
        editor.load(track, projectURL: nil)
        editor.setAvailable(true)
        timeline.onImageSelect?(clip.id, 3)
        editor.currentTime = 2

        let field = try XCTUnwrap(control("visuals.value.scale", in: editor.view) as DragValueField?)
        func event(_ type: NSEvent.EventType, x: Double = 100, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: clicks, pressure: 1)!
        }
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseUp(with: event(.leftMouseUp))
        XCTAssertNil(field.currentEditor())
        field.mouseDown(with: event(.leftMouseDown, clicks: 2))
        XCTAssertNotNil(field.currentEditor())
        XCTAssertTrue(window.makeFirstResponder(nil))

        var previews = [VisualTrack]()
        var commits = 0
        editor.onPreview = { previews.append($0) }
        editor.onChange = { _ in commits += 1 }
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseDragged(with: event(.leftMouseDragged, x: 117))
        XCTAssertEqual(editor.track, track)
        XCTAssertEqual(previews.last?.clip(clip.id)?.fixedValues[.scale], 117)
        field.mouseUp(with: event(.leftMouseUp, x: 120))
        XCTAssertEqual(editor.track.clip(clip.id)?.fixedValues[.scale], 120)
        XCTAssertEqual(commits, 1)

        XCTAssertNil(control("visuals.key.scale", in: editor.view) as NSButton?)
        XCTAssertFalse(field.hasAutomation)
        try performAutomationMenu(field, title: "オートメーションを作成")
        XCTAssertTrue(field.hasAutomation)
        let bitmap = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/my_movie-automation-badge.png"))
        let keyed = editor.track
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseDragged(with: event(.leftMouseDragged, x: 110))
        XCTAssertTrue(editor.cancelValueDrag())
        field.mouseUp(with: event(.leftMouseUp, x: 110))
        XCTAssertEqual(editor.track, keyed)
        XCTAssertEqual(Double(field.stringValue), 120)
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseDragged(with: event(.leftMouseDragged, x: 115))
        field.mouseUp(with: event(.leftMouseUp, x: 115))
        XCTAssertEqual(Double(field.stringValue), 135)
        let shifted = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertEqual(shifted.baseValue(.scale), 135)
        XCTAssertEqual(shifted.curve(.scale)?.keys.first?.value, 135)
        XCTAssertEqual(shifted.curve(.scale)?.minimum, 25)
        XCTAssertEqual(shifted.curve(.scale)?.maximum, 215)
        XCTAssertEqual(commits, 3)

        let minimum = try XCTUnwrap(control("visuals.graph.minimum", in: editor.view) as DragValueField?)
        let maximum = try XCTUnwrap(control("visuals.graph.maximum", in: editor.view) as DragValueField?)
        for bound in [minimum, maximum] {
            bound.mouseDown(with: event(.leftMouseDown))
            bound.mouseDragged(with: event(.leftMouseDragged, x: 110))
            bound.mouseUp(with: event(.leftMouseUp, x: 110))
        }
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 35)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.maximum, 225)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.value, 135)

        let middle = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                            mouseCursorPosition: .zero, mouseButton: .center))
        let reset = try XCTUnwrap(NSEvent(cgEvent: middle))
        field.otherMouseDown(with: reset)
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.scale), 100)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.value, 100)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 10)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.maximum, 190)
        maximum.mouseDown(with: event(.leftMouseDown))
        maximum.mouseDragged(with: event(.leftMouseDragged, x: 115))
        maximum.mouseUp(with: event(.leftMouseUp, x: 115))
        maximum.otherMouseDown(with: reset)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.maximum, 200)
        minimum.mouseDown(with: event(.leftMouseDown))
        minimum.mouseDragged(with: event(.leftMouseDragged, x: 105))
        minimum.mouseUp(with: event(.leftMouseUp, x: 105))
        minimum.otherMouseDown(with: reset)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 10)
        let automated = editor.track
        let commitsBeforeDelete = commits
        try performAutomationMenu(field, title: "オートメーションを削除")
        XCTAssertFalse(field.hasAutomation)
        XCTAssertNil(editor.track.clip(clip.id)?.curve(.scale))
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.scale), 100)
        XCTAssertEqual(commits, commitsBeforeDelete + 1)
        editor.load(automated, projectURL: nil)
        timeline.onImageSelect?(clip.id, 3)
        XCTAssertTrue(field.hasAutomation, "復元時に青い丸も復元する")
        editor.setAvailable(false)
        XCTAssertNil(automationMenu(field))
    }

    @MainActor func testInspectorAndGraphAddMoveCancelAndDelete() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = timeline
        defer { window.close() }
        let editor = VisualEditor()
        _ = editor.view
        editor.timeline = timeline
        let grid = TimelineSnapGrid(division: .quarter)
        editor.snapGrid = grid
        timeline.snapGrid = grid
        let (track, clip) = try fixture()
        editor.duration = 10
        editor.load(track, projectURL: nil)
        editor.setAvailable(true)
        timeline.visualMode = true
        timeline.duration = 10
        timeline.onSeek = { time in timeline.currentTime = time; editor.currentTime = time }
        editor.onSeek = timeline.onSeek
        defer { timeline.onSeek = nil; editor.onSeek = nil }
        timeline.onImageSelect?(clip.id, 3)
        timeline.onSeek?(1.52)

        let value = try XCTUnwrap(control("visuals.value.scale", in: editor.view) as NSTextField?)
        let knob = try XCTUnwrap(value as? DragValueField)
        value.stringValue = "150"
        try performAutomationMenu(knob, title: "オートメーションを作成")
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.time, 0.5)
        XCTAssertTrue(timeline.expandedLayerSlots.contains(3))
        XCTAssertEqual(timeline.selectedParameter, .scale)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.value, 150)
        let minimum = try XCTUnwrap(control("visuals.graph.minimum", in: editor.view) as NSTextField?)
        let maximum = try XCTUnwrap(control("visuals.graph.maximum", in: editor.view) as NSTextField?)
        minimum.stringValue = "50"; maximum.stringValue = "150"
        XCTAssertTrue(maximum.sendAction(maximum.action, to: maximum.target))
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 50)
        XCTAssertEqual(editor.track.clip(clip.id)?.manualValue(.scale, at: 2), 150)

        func event(_ type: NSEvent.EventType, time: Double, y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(NSPoint(x: timeline.x(at: time), y: y), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        timeline.onSeek?(1.52)
        timeline.mouseDown(with: event(.leftMouseDown, time: 2.62, y: 125))
        timeline.mouseUp(with: event(.leftMouseUp, time: 2.62, y: 125))
        XCTAssertEqual(timeline.currentTime, 1.52, "点を追加しても再生ヘッドを移動しない")
        XCTAssertEqual(editor.currentTime, 1.52)
        let added = editor.track
        let key = try XCTUnwrap(added.clip(clip.id)?.curve(.scale)?.keys.last)
        XCTAssertEqual(key.time, 1.5)
        XCTAssertEqual(key.value, 100, accuracy: 1e-9)
        XCTAssertEqual(timeline.selectedKeyID, key.id)

        func hasYellowMarker() throws -> Bool {
            let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            let scale = Double(bitmap.pixelsWide) / timeline.bounds.width
            let x = Int((timeline.x(at: 2.5) + 4.5) * scale)
            return (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.75 && color.greenComponent > 0.6 && color.blueComponent < 0.5
            }
        }
        timeline.mouseMoved(with: event(.mouseMoved, time: 2.5, y: 134))
        XCTAssertTrue(try hasYellowMarker(), "当たり判定内では通常のマーカーより外側まで黄色で表示する")
        timeline.mouseMoved(with: event(.mouseMoved, time: 2.5, y: 141))
        XCTAssertFalse(try hasYellowMarker())
        timeline.mouseDown(with: event(.leftMouseDown, time: 2.5, y: 134))
        XCTAssertEqual(timeline.selectedKeyID, key.id, "点の中心から9pt離れていても掴める")
        XCTAssertEqual(timeline.currentTime, 2.5, "既存の点を選ぶとその時刻に移動する")
        timeline.mouseDragged(with: event(.leftMouseDragged, time: 2.85, y: 121))
        XCTAssertEqual(editor.track, added)
        timeline.cancelDrag()
        XCTAssertEqual(editor.track, added)
        timeline.mouseDown(with: event(.leftMouseDown, time: 2.5, y: 134))
        timeline.mouseDragged(with: event(.leftMouseDragged, time: 2.85, y: 121))
        timeline.mouseUp(with: event(.leftMouseUp, time: 2.85, y: 121))
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.last?.time, 2)
        XCTAssertEqual(timeline.selectedKeyID, key.id)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                      charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        timeline.keyDown(with: delete)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.count, 1)
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil),
                                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { timeline.mouseDown(with: event) } else { timeline.mouseUp(with: event) }
            }
        }
        click(NSPoint(x: timeline.x(at: 4), y: 69))
        XCTAssertNil(timeline.selectedImageID)
        XCTAssertTrue(timeline.expandedLayerSlots.contains(3), "空白をクリックしてもレーンを収納しない")
        click(NSPoint(x: 65, y: 69))
        XCTAssertFalse(timeline.expandedLayerSlots.contains(3))
        click(NSPoint(x: 65, y: 69))
        XCTAssertTrue(timeline.expandedLayerSlots.contains(3))
        click(NSPoint(x: timeline.x(at: 1.5), y: 98))
        XCTAssertEqual(timeline.selectedImageID, clip.id, "レーンからクリップを再選択できる")
        let snap = try XCTUnwrap(control("visuals.keySnap", in: editor.view) as NSButton?)
        snap.performClick(nil)
        timeline.onSeek?(2.123)
        click(NSPoint(x: timeline.x(at: 2.123), y: 125))
        let freeKey = try XCTUnwrap(editor.track.clip(clip.id)?.curve(.scale)?.keys.last)
        XCTAssertEqual(freeKey.time, 1.123, accuracy: 1e-9)
        snap.performClick(nil)
        click(NSPoint(x: timeline.x(at: 2.123), y: 125))
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.count, 2)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.last?.id, freeKey.id)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.last?.value, freeKey.value)
        XCTAssertEqual(Double(value.stringValue), 150)

        func contextMenu(at point: NSPoint) -> NSMenu? {
            let click = NSEvent.mouseEvent(with: .rightMouseDown, location: timeline.convert(point, to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return timeline.menu(for: click)
        }
        let original = editor.track
        XCTAssertNil(contextMenu(at: NSPoint(x: timeline.x(at: 2), y: 105)))
        let menu = try XCTUnwrap(contextMenu(at: NSPoint(x: 20, y: 105)))
        let removal = try XCTUnwrap(menu.item(withTitle: "レーンを削除"))
        XCTAssertEqual(editor.track, original)
        var commits = 0
        editor.onChange = { _ in commits += 1 }
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(removal.action), to: removal.target, from: removal))
        XCTAssertEqual(commits, 1)
        let updated = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertNil(updated.curve(.scale))
        XCTAssertFalse(knob.hasAutomation, "レーンから削除してもノブの表示を更新する")
        XCTAssertEqual(updated.manualValue(.scale, at: 2), 150)
        XCTAssertNil(timeline.selectedParameter)
        XCTAssertNil(timeline.selectedKeyID)
        XCTAssertEqual(timeline.currentTime, 2.123)
        XCTAssertNil(contextMenu(at: NSPoint(x: 20, y: 105)))
    }
}
