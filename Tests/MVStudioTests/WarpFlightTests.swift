import AppKit
import XCTest
@testable import MVStudio

final class WarpFlightTests: XCTestCase {
    func testPersistenceAutomationAndTrim() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(warpFlight: .init()))
        for parameter in ImageEffects.WarpFlight.parameters {
            let effect = try XCTUnwrap(parameter.effect)
            _ = clip.setKey(parameter, at: 1, value: effect.range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: effect.range.upperBound)
            XCTAssertTrue(clip.automationParameters.contains(parameter))
            XCTAssertEqual(effect.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), (effect.range.lowerBound + effect.range.upperBound) / 2)
        }
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.warpFlight?.phaseOffset, 1)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        XCTAssertTrue(clip.effects?.isValid == true)
        clip.effects?.warpFlight?.zoom = 0
        XCTAssertFalse(clip.effects?.isValid == true)
    }

    func testRenderingSeekOpacityAndTrim() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(warpFlight: .init())
        func pixels() -> [[UInt8]] {
            stride(from: 10, to: 270, by: 25).flatMap { y in
                stride(from: 10, to: 480, by: 25).map { canvas.pixel($0, y) }
            }
        }
        try canvas.draw([(clip, 0)], time: 0.5)
        let first = pixels()
        XCTAssertTrue(first.contains { $0[0] > 30 })
        try canvas.save("/tmp/my-movie-warp-preview.png")
        try canvas.draw([(clip, 0)], time: 1.5)
        XCTAssertNotEqual(first, pixels())
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.trimStart(to: 0.25)
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.effects?.warpFlight?.opacity = 0
        try canvas.draw([(clip, 0)], time: 0.5)
        let hidden = pixels()
        clip.effects = nil
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(hidden, pixels())
    }
    @MainActor func testEditorAddToggleDeleteAndAutomation() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
        func load() { editor.load(clip, editable: true) }
        load()
        editor.onCommit = { clip.effects = $0; load() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(editor)
        let add = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "ワープ航行"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.warpFlight)
        XCTAssertFalse(try XCTUnwrap(add.menu?.effectItem(titled: item.title + "（追加済み）")).isEnabled)
        for parameter in ImageEffects.WarpFlight.parameters {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, 100)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.warpFlight?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.warpFlight)
    }

}
