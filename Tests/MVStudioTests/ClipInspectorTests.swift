import AppKit
import XCTest
@testable import MVStudio

final class ClipInspectorTests: XCTestCase {
    @MainActor private func fixture() -> (VisualEditor, TimelineView, VisualClip) {
        _ = NSApplication.shared
        let editor = VisualEditor(); _ = editor.view
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        editor.timeline = timeline; editor.duration = 20
        var clip = VisualClip(start: 0, end: 10)
        var effects = ImageEffects(); effects.bloom = .init()
        clip.effects = effects
        var track = VisualTrack(); track.layers[0].clips = [clip]
        editor.load(track, projectURL: nil); editor.setAvailable(true)
        timeline.onImageSelect?(clip.id, track.layers[0].id)
        return (editor, timeline, clip)
    }

    @MainActor private func find<T: NSView>(_ id: String, in root: NSView, as type: T.Type) throws -> T {
        func visit(_ view: NSView) -> T? {
            if view.identifier?.rawValue == id { return view as? T }
            return view.subviews.lazy.compactMap(visit).first
        }
        return try XCTUnwrap(visit(root))
    }

    @MainActor func testSingleTargetSelectionHasNoModelOrPlaybackSideEffects() throws {
        let (editor, timeline, clip) = fixture()
        var saves = 0, seeks = 0
        editor.onChange = { _ in saves += 1 }; editor.onSeek = { _ in seeks += 1 }
        timeline.currentTime = 2.5
        let original = editor.track
        let x = try find("visuals.value.x", in: editor.view, as: DragValueField.self)
        x.onSelect?()
        XCTAssertEqual(editor.inspectionParameter, .x)
        XCTAssertEqual(editor.lfoEditor.parameter, .x)
        XCTAssertEqual(editor.musicEditor.parameter, .x)
        XCTAssertNil(timeline.selectedParameter)
        let bloom = try find("visuals.value.bloomIntensity", in: editor.view, as: DragValueField.self)
        bloom.onSelect?()
        XCTAssertEqual(editor.inspectionParameter, .bloomIntensity)
        XCTAssertEqual(editor.inspectionNodeID, clip.effects?.node(for: .bloomIntensity)?.id)
        XCTAssertEqual(editor.lfoEditor.parameter, .bloomIntensity)
        XCTAssertEqual(editor.musicEditor.parameter, .bloomIntensity)
        let path = try find("clip.target.path", in: editor.view, as: NSTextField.self)
        XCTAssertEqual(path.stringValue, "対象：ブルーム › 強さ")
        XCTAssertEqual(editor.track, original)
        XCTAssertEqual(timeline.currentTime, 2.5)
        XCTAssertEqual(saves, 0); XCTAssertEqual(seeks, 0)
        XCTAssertNil(editor.track.clip(clip.id)?.automation(.bloomIntensity))
    }

    @MainActor func testTimelineAndTargetMenuAgreeAndClearAnUncreatedLane() throws {
        let (editor, timeline, clip) = fixture()
        var track = editor.track
        var keyed = clip
        _ = keyed.setKey(.x, at: 0, value: 10)
        track.layers[0].clips = [keyed]
        editor.restore(track)
        timeline.selectGraph(.x)
        XCTAssertEqual(editor.inspectionParameter, .x)
        let picker = try find("clip.target.change", in: editor.view, as: NSPopUpButton.self)
        let item = try XCTUnwrap(picker.menu?.items.first { $0.representedObject as? String == ImageParameter.bloomIntensity.rawValue })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(editor.inspectionParameter, .bloomIntensity)
        XCTAssertNil(timeline.selectedParameter)
        timeline.selectGraph(.x)
        XCTAssertEqual(editor.inspectionParameter, .x)
        XCTAssertEqual(editor.lfoEditor.parameter, .x)
    }

    @MainActor func testNodeSelectionRemembersParametersAndDeletionRestoresBasicTarget() throws {
        let (editor, _, clip) = fixture()
        let effects = try XCTUnwrap(editor.view.subviews.lazy.flatMap { self.descendants($0) }.first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        let id = try XCTUnwrap(clip.effects?.node(for: .bloomIntensity)?.id)
        effects.onSelectNode?(id)
        XCTAssertNil(editor.inspectionParameter)
        XCTAssertTrue(editor.lfoEditor.isHidden)
        editor.selectInspectionParameter(.bloomRadius)
        editor.selectInspectionParameter(.x)
        effects.onSelectNode?(id)
        XCTAssertEqual(editor.inspectionParameter, .bloomRadius)
        var removed = editor.track; removed.layers[0].clips[0].effects = nil
        editor.restore(removed)
        XCTAssertEqual(editor.inspectionParameter, .scale)
        XCTAssertNil(editor.inspectionNodeID)
        editor.restore(VisualTrack())
        XCTAssertNil(editor.track.clip(clip.id))
        XCTAssertTrue(editor.lfoEditor.isHidden)
    }

    @MainActor func testSelectionSurvivesRestoreAndResetsAcrossClips() throws {
        let (editor, timeline, clip) = fixture()
        editor.selectInspectionParameter(.bloomRadius)
        var edited = editor.track
        edited.layers[0].clips[0].setBaseValue(35, for: .bloomRadius)
        editor.restore(edited)
        XCTAssertEqual(editor.inspectionParameter, .bloomRadius)
        XCTAssertEqual(editor.inspectionNodeID, clip.effects?.node(for: .bloomRadius)?.id)
        let other = VisualClip(start: 12, end: 18)
        edited.layers[0].clips.append(other)
        editor.restore(edited)
        timeline.onImageSelect?(other.id, edited.layers[0].id)
        XCTAssertEqual(editor.inspectionParameter, .scale)
        XCTAssertNil(editor.inspectionNodeID)
        timeline.onImageSelect?(clip.id, edited.layers[0].id)
        XCTAssertEqual(editor.inspectionParameter, .scale)
    }

    @MainActor func testEmitterRemovalTracksParameterAndClearsDeletedTarget() throws {
        let (editor, _, clip) = fixture()
        var edited = editor.track
        var effects = try XCTUnwrap(clip.effects)
        var particles = ImageEffects.Particles(seed: 0)
        particles.addEmitter(); particles.addEmitter()
        effects.particles = particles
        edited.layers[0].clips[0].effects = effects
        editor.restore(edited)
        editor.selectInspectionParameter(.emitter2Y)
        let effectsEditor = try XCTUnwrap(descendants(editor.view).first { $0 is ImageEffectsEditor } as? ImageEffectsEditor)
        var reduced = effects
        reduced.particles?.emitters.remove(at: 0)
        effectsEditor.onDeleteEmitter?(reduced, 0)
        XCTAssertEqual(editor.inspectionParameter, .emitter1Y)
        reduced = try XCTUnwrap(editor.track.clip(clip.id)?.effects)
        reduced.particles?.emitters.remove(at: 1)
        effectsEditor.onDeleteEmitter?(reduced, 1)
        XCTAssertNil(editor.inspectionParameter)
        XCTAssertTrue(editor.lfoEditor.isHidden)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor func testHeaderIsFixedAndHiddenOnOtherTabs() throws {
        _ = NSApplication.shared
        let placement = PlacementEditor(); _ = placement.view
        placement.restoreTab(.visuals)
        XCTAssertFalse(placement.visuals.inspectionHeader.isHidden)
        XCTAssertTrue(placement.visuals.inspectionHeader.superview === placement.inspector)
        XCTAssertNil(placement.visuals.inspectionHeader.enclosingScrollView)
        let tabs = try find("placement.mode", in: placement.inspector, as: NSSegmentedControl.self)
        XCTAssertEqual(tabs.label(forSegment: 1), "クリップ")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let container = NSView(); window.contentView = container
        let inspector = placement.inspector
        container.addSubview(inspector)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inspector.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: container.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        var clip = VisualClip(start: 0, end: 10)
        var effects = ImageEffects(); effects.bloom = .init(); clip.effects = effects
        var track = VisualTrack(); track.layers[0].clips = [clip]
        placement.duration = 20
        placement.visuals.load(track, projectURL: nil)
        placement.setAvailable(hasAudio: true, isBusy: false)
        placement.timeline.onImageSelect?(clip.id, track.layers[0].id)
        placement.visuals.selectInspectionParameter(.bloomIntensity)
        var lfo = LFOSettings(); lfo.amount = 20
        placement.visuals.lfoEditor.onCommit?(.bloomIntensity, .lfo, lfo)
        container.layoutSubtreeIfNeeded()
        let headerFrame = placement.visuals.inspectionHeader.frame
        XCTAssertGreaterThan(headerFrame.height, 30)
        XCTAssertLessThan(headerFrame.height, 70)
        placement.visuals.lfoEditor.scrollToVisible(placement.visuals.lfoEditor.bounds)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(placement.visuals.inspectionHeader.frame, headerFrame)
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
        try png.write(to: URL(fileURLWithPath: "/tmp/my-movie-clip-inspector-pinned.png"))
        placement.restoreTab(.spectrum)
        XCTAssertTrue(placement.visuals.inspectionHeader.isHidden)
        XCTAssertTrue(placement.visualMode)
        placement.restoreTab(.lyrics)
        XCTAssertTrue(placement.visuals.inspectionHeader.isHidden)
    }
}
