import XCTest
import AppKit
@testable import MVStudio

final class LyricsEditorTests: XCTestCase {
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
        let end = try XCTUnwrap(find(editor.view, "lyrics.end") as? NSTextField)
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
    }

}
