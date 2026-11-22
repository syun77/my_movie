import XCTest
import AppKit
@testable import MVStudio

final class LyricsEditorTests: XCTestCase {
    @MainActor func testGlowColorControlCommitsAndRestores() throws {
        let editor = LyricsEditor()
        _ = editor.view
        editor.setAvailable(true)
        func find(_ view: NSView) -> NSColorWell? {
            if view.identifier?.rawValue == "lyrics.glowColor" { return view as? NSColorWell }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let well = try XCTUnwrap(find(editor.view))
        var saved = [LyricsTrack]()
        editor.onChange = { saved.append($0) }
        well.color = .red
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(well.action), to: well.target, from: well))
        XCTAssertEqual(editor.track.glowColor, RGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(editor.track.outlineColor, .black)
        XCTAssertEqual(saved.count, 1)
        var restored = editor.track
        restored.glowColor = RGBColor(red: 0, green: 0, blue: 1)
        editor.restore(restored)
        XCTAssertEqual(RGBColor(well.color), restored.glowColor)
        editor.setAvailable(false)
        XCTAssertFalse(well.isEnabled)
    }

    @MainActor func testGlowWidthEditingAndReset() throws {
        let editor = LyricsEditor()
        _ = editor.view
        editor.setAvailable(true)
        func find(_ view: NSView) -> DragValueField? {
            if view.identifier?.rawValue == "lyrics.glowWidth" { return view as? DragValueField }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let field = try XCTUnwrap(find(editor.view))
        var changes = 0
        editor.onChange = { _ in changes += 1 }
        field.stringValue = "24"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(editor.track.glowWidth, 24)
        XCTAssertEqual(editor.track.outlineWidth, 3)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(field.resetValue())
        XCTAssertEqual(editor.track.glowWidth, 0)
        XCTAssertEqual(changes, 2)
    }

    @MainActor func testAutomaticTextAndTimeChangesPreserveEditingState() throws {
        let editor = LyricsEditor()
        _ = editor.view
        editor.duration = 10; editor.setAvailable(true); editor.currentTime = 1
        editor.perform(NSSelectorFromString("addClip"))
        func find(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0, id) }.first
        }
        let body = try XCTUnwrap(find(editor.view, "lyrics.body") as? NSTextView)
        let start = try XCTUnwrap(find(editor.view, "lyrics.start") as? NSTextField)
        let end = try XCTUnwrap(find(editor.view, "lyrics.end") as? DragValueField)
        var saved = [LyricsTrack]()
        editor.onChange = { saved.append($0) }
        body.string = "自動反映"; body.setSelectedRange(NSRange(location: 2, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        XCTAssertEqual(editor.track.clips.first?.text, "自動反映")
        XCTAssertEqual(body.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(saved.count, 1)
        start.stringValue = "1.25"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: start))
        XCTAssertEqual(editor.track.clips.first?.start, 1.25)
        XCTAssertEqual(start.stringValue, "1.25", "入力中に表示を書き換えない")
        end.stringValue = ""
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
        XCTAssertEqual(editor.track.clips.first?.end, 3.25)
        XCTAssertEqual(saved.count, 2)
        end.stringValue = "4.5"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
        XCTAssertEqual(editor.track.clips.first?.end, 4.5)
        body.string = ""
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        XCTAssertEqual(editor.track.clips.first?.text, "", "全文削除も即時反映")
        editor.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: body))
        XCTAssertEqual(saved.count, 4, "同一内容は重複保存しない")
        body.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        XCTAssertEqual(saved.count, 4, "IME変換中は確定モデルを変更しない")
        body.unmarkText()
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        XCTAssertEqual(editor.track.clips.first?.text, "か")
        XCTAssertEqual(saved.count, 5)

        func mouse(_ type: NSEvent.EventType, x: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 0), modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        end.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        end.mouseDragged(with: try mouse(.leftMouseDragged, x: 147))
        XCTAssertEqual(saved.count, 5)
        end.mouseUp(with: try mouse(.leftMouseUp, x: 149))
        XCTAssertEqual(editor.track.clips.first?.end, 5)
        XCTAssertEqual(saved.count, 6)
        XCTAssertTrue(end.resetValue())
        XCTAssertEqual(editor.track.clips.first?.end, 3.25)
    }
}
