import AppKit
import XCTest
@testable import MVStudio

final class InspectorFilterTests: XCTestCase {
    @MainActor private func fixture(_ configure: (inout VisualClip) -> Void = { _ in }) -> (VisualEditor, TimelineView, VisualClip) {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: InspectorFilter.defaultsKey)
        UserDefaults.standard.removeObject(forKey: InspectorFilter.defaultsKey)
        addTeardownBlock {
            if let previous { UserDefaults.standard.set(previous, forKey: InspectorFilter.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InspectorFilter.defaultsKey) }
        }
        let editor = VisualEditor(); _ = editor.view
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        editor.timeline = timeline; editor.duration = 30
        var clip = VisualClip(start: 0, end: 10)
        configure(&clip)
        var track = VisualTrack()
        if clip.content.isVideo {
            clip.assetID = track.register(url: URL(fileURLWithPath: "/tmp/filter-video.mov"), projectURL: URL(fileURLWithPath: "/tmp/filter.mvproject"), kind: .video(duration: 120))
        }
        track.layers[0].clips = [clip]
        editor.load(track, projectURL: nil); editor.setAvailable(true)
        timeline.onImageSelect?(clip.id, track.layers[0].id)
        return (editor, timeline, clip)
    }

    @MainActor private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    @MainActor private func field(_ parameter: ImageParameter, in editor: VisualEditor) throws -> DragValueField {
        try XCTUnwrap(descendants(editor.view).first { $0.identifier?.rawValue == "visuals.value." + parameter.rawValue } as? DragValueField)
    }
    @MainActor private func toggle(_ editor: VisualEditor, modified: Bool = true) throws {
        let control = try XCTUnwrap(descendants(editor.filterBar).first { $0.identifier?.rawValue == "clip.filter.mode" } as? NSButton)
        control.state = modified ? .on : .off
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control))
    }
    @MainActor private func picker(_ editor: VisualEditor) throws -> NSPopUpButton {
        try XCTUnwrap(descendants(editor.filterBar).first { $0 is NSPopUpButton } as? NSPopUpButton)
    }
    @MainActor private func perform(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    func testModelPredicateIncludesDormantAutomationButIgnoresDisplayRange() {
        var clip = VisualClip(start: 0, end: 10)
        XCTAssertFalse(InspectorFilter.isModified(.x, in: clip))
        clip.automationRanges[.x] = .init(lower: -1000, upper: 1000)
        XCTAssertFalse(InspectorFilter.isModified(.x, in: clip))
        clip.setBaseValue(25, for: .x)
        XCTAssertTrue(InspectorFilter.isModified(.x, in: clip))
        clip.setBaseValue(0, for: .x)
        _ = clip.setKey(.x, at: 0, value: 0)
        clip.setAutomationMode(.lfo, for: .x)
        clip.setAutomationMode(.keys, for: .x)
        XCTAssertTrue(InspectorFilter.isModified(.x, in: clip))
        clip.removeAutomation(.x)
        var sync = AudioModulation.initial(for: .x); sync.enabled = false
        clip.audioModulations[.x] = sync
        XCTAssertTrue(InspectorFilter.isModified(.x, in: clip))
        XCTAssertFalse(InspectorFilter.differs(100 + 1e-10, from: 100))
    }

    @MainActor func testFilterHasNoEditSideEffectsAndPlaybackDoesNotChangeVisibility() throws {
        let (editor, timeline, _) = fixture { $0.setBaseValue(120, for: .x) }
        let original = editor.track
        var saves = 0, seeks = 0
        editor.onChange = { _ in saves += 1 }; editor.onSeek = { _ in seeks += 1 }
        try toggle(editor)
        XCTAssertFalse(try field(.x, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try field(.y, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try field(.scale, in: editor).isHiddenOrHasHiddenAncestor)
        for time in [0.0, 2.0, 9.0, 15.0] {
            editor.currentTime = time; timeline.currentTime = time
            XCTAssertFalse(try field(.x, in: editor).isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(try field(.y, in: editor).isHiddenOrHasHiddenAncestor)
        }
        XCTAssertEqual(editor.track, original)
        XCTAssertEqual(saves, 0); XCTAssertEqual(seeks, 0)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: InspectorFilter.defaultsKey))
        let other = VisualEditor(); _ = other.view
        let mode = try XCTUnwrap(descendants(other.filterBar).first { $0.identifier?.rawValue == "clip.filter.mode" } as? NSButton)
        XCTAssertEqual(mode.state, .on)
        XCTAssertEqual(mode.title, "変更のみ")
    }

    @MainActor func testPickerRevealsDefaultAndResetRemainsUntilAnotherSelection() throws {
        let (editor, _, _) = fixture { $0.setBaseValue(25, for: .x) }
        try toggle(editor)
        let item = try XCTUnwrap(try picker(editor).menu?.items.first { $0.representedObject as? String == "y" })
        let original = editor.track
        try perform(item)
        XCTAssertFalse(try field(.y, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(editor.track, original)
        let y = try field(.y, in: editor)
        y.onReset?()
        XCTAssertFalse(y.isHiddenOrHasHiddenAncestor)
        editor.selectInspectionParameter(.x)
        XCTAssertTrue(y.isHiddenOrHasHiddenAncestor)
        let x = try field(.x, in: editor)
        x.onReset?()
        XCTAssertEqual(editor.track.layers[0].clips[0].baseValue(.x), 0)
        XCTAssertFalse(x.isHiddenOrHasHiddenAncestor)
        editor.selectInspectionParameter(.rotation)
        XCTAssertTrue(x.isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testEffectsKeepChainAndFilterIndividualNumbersIncludingDisabledSync() throws {
        let (editor, _, clip) = fixture {
            var effects = ImageEffects(); effects.bloom = .init(); $0.effects = effects
            $0.setBaseValue(75, for: .bloomIntensity)
            var sync = AudioModulation.initial(for: .bloomThreshold); sync.enabled = false
            $0.audioModulations[.bloomThreshold] = sync
        }
        let effectsEditor = try XCTUnwrap(descendants(editor.view).first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        let id = try XCTUnwrap(clip.effects?.node(for: .bloomIntensity)?.id)
        effectsEditor.selectNode(id)
        effectsEditor.onSelectNode?(id)
        try toggle(editor)
        XCTAssertFalse(try field(.bloomIntensity, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(try field(.bloomThreshold, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
        let chain = try XCTUnwrap(descendants(editor.view).first { $0 is EffectChainList })
        XCTAssertFalse(chain.isHiddenOrHasHiddenAncestor)
        editor.selectInspectionParameter(.bloomRadius)
        XCTAssertFalse(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(editor.track.clip(clip.id), clip)
    }

    @MainActor func testEffectFullDetailMenuAndDefaultMessage() throws {
        let (editor, _, clip) = fixture {
            var effects = ImageEffects(); effects.bloom = .init(); $0.effects = effects
        }
        let effectsEditor = try XCTUnwrap(descendants(editor.view).first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        let id = try XCTUnwrap(clip.effects?.node(for: .bloomIntensity)?.id)
        effectsEditor.selectNode(id); effectsEditor.onSelectNode?(id)
        try toggle(editor)
        XCTAssertTrue(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
        let notice = try XCTUnwrap(descendants(editor.view).first { $0.identifier?.rawValue == "clip.filter.effectEmpty" })
        XCTAssertFalse(notice.isHiddenOrHasHiddenAncestor)
        let item = try XCTUnwrap(try picker(editor).menu?.items.first { $0.title == "ブルームの全項目を編集…" })
        try perform(item)
        XCTAssertFalse(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(try field(.bloomThreshold, in: editor).isHiddenOrHasHiddenAncestor)
        try toggle(editor, modified: false)
        XCTAssertFalse(try field(.x, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testRestoreAndClipSwitchRecomputeAndPreserveMode() throws {
        let (editor, timeline, clip) = fixture { $0.setBaseValue(10, for: .x) }
        try toggle(editor)
        var changed = editor.track
        changed.layers[0].clips[0].setBaseValue(20, for: .y)
        editor.restore(changed)
        XCTAssertFalse(try field(.y, in: editor).isHiddenOrHasHiddenAncestor)
        changed.layers[0].clips[0].setBaseValue(0, for: .y)
        editor.restore(changed)
        XCTAssertTrue(try field(.y, in: editor).isHiddenOrHasHiddenAncestor)
        let other = VisualClip(start: 15, end: 20)
        changed.layers[0].clips.append(other); editor.restore(changed)
        editor.selectInspectionParameter(.rotation)
        timeline.onImageSelect?(other.id, changed.layers[0].id)
        XCTAssertTrue(try field(.rotation, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try field(.x, in: editor).isHiddenOrHasHiddenAncestor)
        timeline.onImageSelect?(clip.id, changed.layers[0].id)
        XCTAssertFalse(try field(.x, in: editor).isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testNewEffectShowsInitialDetailsAndThenFiltersAfterSelection() throws {
        let (editor, _, _) = fixture()
        try toggle(editor)
        let effects = try XCTUnwrap(descendants(editor.view).first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        let addition = try XCTUnwrap(descendants(effects).compactMap { $0 as? NSPopUpButton }.first { $0.menu?.items.first?.title == "＋ 演出を追加" })
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == "ブルーム" { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        try perform(try XCTUnwrap(find(try XCTUnwrap(addition.menu))))
        XCTAssertNotNil(editor.track.layers[0].clips[0].effects?.bloom)
        XCTAssertFalse(try field(.bloomThreshold, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
        editor.selectInspectionParameter(.bloomRadius)
        XCTAssertFalse(try field(.bloomRadius, in: editor).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try field(.bloomThreshold, in: editor).isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testNonNumericValuesAreComparedWithModelDefaults() throws {
        let (editor, _, clip) = fixture {
            var effects = ImageEffects(); effects.spiralParticles = .init()
            effects.spiralParticles?.color = RGBColor(red: 1, green: 0, blue: 0)
            $0.effects = effects
        }
        let effects = try XCTUnwrap(descendants(editor.view).first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        let id = try XCTUnwrap(clip.effects?.node(for: .spiralCount)?.id)
        effects.selectNode(id); effects.onSelectNode?(id)
        try toggle(editor)
        let wells = descendants(effects).compactMap { $0 as? NSColorWell }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(wells.count, 1)
        XCTAssertEqual(RGBColor(try XCTUnwrap(wells.first).color), RGBColor(red: 1, green: 0, blue: 0))
        XCTAssertTrue(try field(.spiralCount, in: editor).isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testDirectEditingKeepsFieldEditorAndVisibility() throws {
        let (editor, _, _) = fixture { $0.setBaseValue(25, for: .x) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        defer { window.close() }
        try toggle(editor)
        let x = try field(.x, in: editor)
        x.selectText(nil)
        let input = try XCTUnwrap(x.currentEditor() as? NSTextView)
        x.stringValue = "0"
        input.string = "0"
        input.setSelectedRange(NSRange(location: 1, length: 0))
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: x))
        editor.setAvailable(true)
        XCTAssertTrue(x.currentEditor() === input)
        XCTAssertEqual(input.string, "0")
        XCTAssertEqual(input.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertFalse(x.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(x.action), to: x.target, from: x))
        XCTAssertEqual(editor.track.layers[0].clips[0].baseValue(.x), 0)
        XCTAssertTrue(window.makeFirstResponder(nil))
        editor.selectInspectionParameter(.rotation)
        XCTAssertTrue(x.isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testFixedFilterFitsNarrowInspectorAndCapture() throws {
        let (editor, _, clip) = fixture {
            $0.setBaseValue(120, for: .x)
            $0.setBaseValue(115, for: .scale)
            var effects = ImageEffects(); effects.bloom = .init(); $0.effects = effects
            $0.setBaseValue(75, for: .bloomIntensity)
        }
        try toggle(editor)
        let placement = PlacementEditor(); _ = placement.view
        placement.restoreTab(.visuals)
        placement.duration = 30
        placement.visuals.load(editor.track, projectURL: nil)
        placement.setAvailable(hasAudio: true, isBusy: false)
        placement.timeline.onImageSelect?(clip.id, editor.track.layers[0].id)
        let effects = try XCTUnwrap(descendants(placement.visuals.view).first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        let id = try XCTUnwrap(clip.effects?.node(for: .bloomIntensity)?.id)
        effects.selectNode(id); effects.onSelectNode?(id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSView(); window.contentView = host
        defer { window.close() }
        let inspector = placement.inspector
        host.addSubview(inspector)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inspector.leadingAnchor.constraint(equalTo: host.leadingAnchor), inspector.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: host.topAnchor), inspector.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(placement.visuals.filterBar.enclosingScrollView)
        for control in descendants(placement.visuals.filterBar).compactMap({ $0 as? NSControl }) {
            let rect = inspector.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, 450)
        }
        let frame = placement.visuals.filterBar.frame
        placement.visuals.view.scrollToVisible(placement.visuals.view.bounds)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(placement.visuals.filterBar.frame, frame)
        let x = try field(.x, in: placement.visuals)
        let scroll = try XCTUnwrap(x.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        let item = try XCTUnwrap(try picker(placement.visuals).menu?.items.first { $0.representedObject as? String == "x" })
        let original = placement.visuals.track
        try perform(item)
        let target = document.convert(x.bounds, from: x)
        XCTAssertTrue(scroll.contentView.bounds.contains(target))
        XCTAssertEqual(placement.visuals.track, original)
        let bitmap = try XCTUnwrap(inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds))
        inspector.cacheDisplay(in: inspector.bounds, to: bitmap)
        let layerImage = NSImage(size: inspector.bounds.size)
        layerImage.addRepresentation(bitmap)
        let snapshot = NSImage(size: inspector.bounds.size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            layerImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/my-movie-filter-inspector.png"))
        placement.restoreTab(.lyrics)
        XCTAssertTrue(placement.visuals.filterBar.isHidden)
    }

    @MainActor func testVideoSettingsAreFilteredAndCanBeRevealed() throws {
        let (editor, _, _) = fixture { $0.content = .video(sourceIn: 0, speed: 1) }
        try toggle(editor)
        let speed = try XCTUnwrap(descendants(editor.view).first { $0.identifier?.rawValue == "visual.playbackSpeed" })
        XCTAssertTrue(speed.isHiddenOrHasHiddenAncestor)
        let item = try XCTUnwrap(try picker(editor).menu?.items.first { $0.title == "素材・再生設定を編集…" })
        try perform(item)
        XCTAssertFalse(speed.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try XCTUnwrap(speed as? DragValueField).isEnabled)
        editor.selectInspectionParameter(.x)
        XCTAssertTrue(speed.isHiddenOrHasHiddenAncestor)
        var changed = editor.track
        changed.layers[0].clips[0].content = .video(sourceIn: 1, speed: 2)
        editor.restore(changed)
        XCTAssertFalse(speed.isHiddenOrHasHiddenAncestor)
    }
}
