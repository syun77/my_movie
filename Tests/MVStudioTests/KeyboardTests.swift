import AppKit
import XCTest
@testable import MVStudio

final class KeyboardTests: XCTestCase {
    @MainActor func testSpaceAndEscapeRespectTextFocusAndKeyRepeat() throws {
        _ = NSApplication.shared
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var toggles = 0
        window.onTogglePlayback = { toggles += 1 }
        func key(_ code: UInt16, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "\u{1b}", charactersIgnoringModifiers: code == 49 ? " " : "\u{1b}", isARepeat: repeatKey, keyCode: code)!
        }
        window.sendEvent(key(49))
        window.sendEvent(key(49, repeatKey: true))
        XCTAssertEqual(toggles, 1)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(text)
        window.makeFirstResponder(text)
        window.sendEvent(key(49))
        XCTAssertEqual(toggles, 1)
        XCTAssertEqual(text.string, " ", "入力中のSpaceは文字として挿入する")
        text.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedText = text.string
        let selection = text.selectedRange()
        window.sendEvent(key(49, flags: .command))
        window.sendEvent(key(49, repeatKey: true, flags: .command))
        XCTAssertEqual(toggles, 2)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(text.string, markedText)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertTrue(text.hasMarkedText())
        window.sendEvent(key(53))
        XCTAssertFalse(window.firstResponder === text)
        XCTAssertFalse(text.hasMarkedText())
        window.sendEvent(key(49))
        XCTAssertEqual(toggles, 3)
        text.removeFromSuperview()
        let field = NSTextField(string: "120")
        window.contentView!.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        let fieldEditor = window.firstResponder
        window.sendEvent(key(49, flags: .command))
        XCTAssertEqual(toggles, 4)
        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertEqual(field.stringValue, "120")
        window.sendEvent(key(53))
        XCTAssertFalse(window.firstResponder is NSTextView)
        window.sendEvent(key(49))
        XCTAssertEqual(toggles, 5)
        window.sendEvent(key(49, flags: .command))
        XCTAssertEqual(toggles, 6)
    }
}
