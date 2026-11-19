import AppKit
import XCTest
@testable import MVStudio

final class ChromaticAberrationTests: XCTestCase {
    func testPersistenceAutomationAndValidation() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(chromaticAberration: .init()))
        for parameter in [ImageParameter.chromaticAmount, .chromaticAngle] {
            _ = clip.setKey(parameter, at: 1, value: 0)
            _ = clip.setKey(parameter, at: 3, value: 100)
            XCTAssertEqual(parameter.effect?.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), 50)
        }
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.effects?.chromaticAberration?.amount = .nan
        XCTAssertFalse(clip.effects?.isValid == true)
        XCTAssertNil(try JSONDecoder().decode(ImageEffects.self, from: Data("{\"nodes\":[],\"isBypassed\":false}".utf8)).chromaticAberration)
    }

    func testReferencePulseTrimAndPersistence() throws {
        let effect = ImageEffects.ChromaticAberration()
        for time in [0.0, 0.1, 0.5, 1, 8.25] {
            var amount = (1 + sin(time * 6)) * 0.5
            amount *= 1 + sin(time * 16) * 0.5
            amount *= 1 + sin(time * 19) * 0.5
            amount *= 1 + sin(time * 27) * 0.5
            amount = pow(amount, 3) * 0.05
            XCTAssertEqual(effect.displacement(at: time) / 1920, amount, accuracy: 1e-12)
        }
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(chromaticAberration: effect))
        let before = effect.displacement(at: 2)
        clip.trimStart(to: 2)
        XCTAssertEqual(try XCTUnwrap(clip.effects?.chromaticAberration).displacement(at: 1), before, accuracy: 1e-12)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        let saved = Data("{\"isEnabled\":true,\"amount\":8,\"angle\":0}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(ImageEffects.ChromaticAberration.self, from: saved).phaseOffset, 0)
        clip.effects?.chromaticAberration?.phaseOffset = .infinity
        XCTAssertFalse(clip.effects?.isValid == true)
    }

    func testRenderingAndCacheInvalidation() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(shape: .init(), chromaticAberration: .init(amount: 80))
        // A white rectangle makes the displaced red/blue edges measurable.
        clip.effects?.shape?.color = .init(red: 1, green: 1, blue: 1)
        clip.effects?.shape?.geometry.width = 400
        clip.effects?.shape?.geometry.height = 400
        try canvas.draw([(clip, 0)], time: 0)
        let separated = canvas.pixel(188, 135)
        XCTAssertGreaterThan(Int(separated.max() ?? 0), 200)
        XCTAssertGreaterThan(abs(Int(separated[0]) - Int(separated[2])), 150)
        try canvas.save("/tmp/my-movie-chromatic-preview.png")
        try canvas.draw([(clip, 0)], time: .pi / 4)
        XCTAssertLessThan(canvas.pixel(188, 135)[0], 25)
        try canvas.draw([(clip, 0)], time: 0)
        XCTAssertEqual(canvas.pixel(188, 135), separated)
        try canvas.draw([(clip, 0)], time: 0.1)
        XCTAssertLessThan(canvas.pixel(240, 135)[1], 245, "ずれに応じてRGBを減光する")
        XCTAssertGreaterThan(canvas.pixel(240, 135)[1], 180)
        clip.effects?.chromaticAberration?.angle = 90
        try canvas.draw([(clip, 0)], time: 0)
        XCTAssertLessThan(canvas.pixel(188, 135)[0], 25)
        clip.effects?.chromaticAberration?.amount = 0
        try canvas.draw([(clip, 0)], time: 0)
        XCTAssertLessThan(canvas.pixel(188, 135)[0], 25)
        clip.effects?.chromaticAberration = .init(isEnabled: false, amount: 80)
        try canvas.draw([(clip, 0)], time: 0)
        XCTAssertLessThan(canvas.pixel(188, 135)[0], 25)
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
        let item = try XCTUnwrap(add.menu?.effectItem(titled: "色収差"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(clip.effects?.chromaticAberration)
        XCTAssertFalse(try XCTUnwrap(add.menu?.effectItem(titled: item.title + "（追加済み）")).isEnabled)
        for parameter in [ImageParameter.chromaticAmount, .chromaticAngle] {
            let field = try XCTUnwrap(views.compactMap { $0 as? DragValueField }.first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue })
            XCTAssertEqual(field.doubleValue, parameter.effect?.initial)
            XCTAssertNotNil(field.onCreateAutomation)
            XCTAssertNotNil(field.onEditMusic)
        }
        let enabled = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "有効" })
        enabled.state = .off
        XCTAssertTrue(enabled.sendAction(enabled.action, to: enabled.target))
        XCTAssertEqual(clip.effects?.chromaticAberration?.isEnabled, false)
        let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "削除" })
        XCTAssertTrue(remove.sendAction(remove.action, to: remove.target))
        XCTAssertNil(clip.effects?.chromaticAberration)
    }

}
