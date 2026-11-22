import AppKit
import XCTest
@testable import MVStudio

@MainActor
extension NSMenu {
    func effectItem(titled title: String) -> NSMenuItem? {
        for item in items {
            if item.title == title { return item }
            if let found = item.submenu?.effectItem(titled: title) { return found }
        }
        return nil
    }
}

final class EffectCategoryTests: XCTestCase {
    func testCategoriesCoverEveryAddableKindExactlyOnce() {
        let kinds = EffectCategory.allCases.flatMap(\.kinds)
        XCTAssertEqual(kinds.count, 30)
        XCTAssertEqual(Set(kinds).count, kinds.count)
        XCTAssertEqual(Set(kinds), Set(EffectKind.allCases.filter { $0 != .belowMask }))
    }

    @MainActor func testCompletedCategoriesAndDisabledEffectsRemainVisible() throws {
        _ = NSApplication.shared
        var effects = ImageEffects()
        for kind in EffectCategory.allCases.flatMap(\.kinds) { effects.set(kind, payload: kind.initial) }
        effects.snow?.isEnabled = false
        var calls = 0
        let menu = EffectCategory.additionMenu(effects: effects, editable: true) { _ in calls += 1 }
        XCTAssertEqual(menu.items.count, 6)
        for category in menu.items {
            XCTAssertTrue(category.isEnabled)
            XCTAssertTrue(category.title.hasSuffix("（すべて追加済み）"))
            for item in try XCTUnwrap(category.submenu).items {
                XCTAssertFalse(item.isEnabled)
                XCTAssertTrue(item.title.hasSuffix("（追加済み）"))
            }
        }
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testInsertionSelectionAndStaleMenuGuards() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        var clip = VisualClip(start: 0, end: 4, effects: ImageEffects(blur: .init()))
        var commits = 0
        editor.time = 2
        editor.onCommit = { effects in
            commits += 1
            clip.effects = effects
            editor.load(clip, editable: true)
        }
        editor.load(clip, editable: true)
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let add = try XCTUnwrap(all(editor).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        let list = try XCTUnwrap(all(editor).compactMap { $0 as? EffectChainList }.first)
        let blur = try XCTUnwrap(clip.effects?.nodes.first)
        let context = try XCTUnwrap(list.menuForNode?(blur.id))
        let insertion = try XCTUnwrap(context.item(withTitle: "この後に追加")?.submenu)
        XCTAssertEqual(insertion.items.map(\.title), EffectCategory.allCases.map(\.rawValue))
        let snow = try XCTUnwrap(insertion.effectItem(titled: "雪"))
        func invoke(_ item: NSMenuItem) throws {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        try invoke(snow)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(clip.effects?.nodes.map(\.kind), [.blur, .snow])
        XCTAssertEqual(list.selectedID, clip.effects?.nodes.last?.id)
        let selectedID = try XCTUnwrap(list.selectedID)
        let visibleFields = all(editor).compactMap { $0 as? DragValueField }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertFalse(visibleFields.isEmpty)
        for _ in 0..<2 {
            list.onSelect?(selectedID)
            XCTAssertTrue(visibleFields.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        }
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(editor.time, 2)
        try invoke(snow) // A menu retained across a commit must not add a duplicate.
        XCTAssertEqual(commits, 1)
        let stale = try XCTUnwrap(add.menu?.effectItem(titled: "図形"))
        editor.load(VisualClip(start: 0, end: 4), editable: true)
        try invoke(stale)
        XCTAssertEqual(commits, 1)
        editor.load(clip, editable: true)
        let blocked = try XCTUnwrap(add.menu?.effectItem(titled: "図形"))
        editor.load(clip, editable: false)
        try invoke(blocked)
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(add.isEnabled)
        clip.effects?.snow?.isEnabled = false
        editor.load(clip, editable: true)
        XCTAssertNotNil(add.menu?.effectItem(titled: "雪（追加済み）"))
        XCTAssertEqual(list.nodes.map(\.kind), [.blur, .snow])
        XCTAssertFalse(try XCTUnwrap(list.nodes.last).isEnabled)
        XCTAssertEqual(commits, 1)
        for kind in EffectCategory.allCases.flatMap(\.kinds) { clip.effects?.set(kind, payload: kind.initial) }
        editor.load(clip, editable: true)
        XCTAssertTrue(add.isEnabled)
        XCTAssertEqual(add.menu?.items.dropFirst().filter { $0.title.hasSuffix("（すべて追加済み）") }.count, 6)
    }
}
