import AppKit
import XCTest
@testable import MVStudio

final class PreviewHandleTests: XCTestCase {
    func testCoordinatesAndExplicitPositionPairs() throws {
        let rect = CGRect(x: 20, y: 30, width: 960, height: 540)
        XCTAssertEqual(PreviewHandleCoordinates.movieRect(in: CGRect(x: 0, y: 0, width: 1000, height: 540)), CGRect(x: 20, y: 0, width: 960, height: 540))
        XCTAssertEqual(PreviewHandleCoordinates.movieRect(in: CGRect(x: 0, y: 0, width: 960, height: 600)), CGRect(x: 0, y: 30, width: 960, height: 540))
        let centered = PreviewHandleCoordinates(centered: true)
        XCTAssertEqual(centered.view(.zero, in: rect), CGPoint(x: 500, y: 300))
        XCTAssertEqual(centered.translated(.zero, by: CGPoint(x: 25, y: 15), in: rect), CGPoint(x: 50, y: -30))
        let corner = PreviewHandleCoordinates()
        XCTAssertEqual(corner.view(CGPoint(x: 100, y: 200), in: rect), CGPoint(x: 70, y: 130))
        XCTAssertEqual(corner.translated(CGPoint(x: 100, y: 200), by: CGPoint(x: 25, y: 15), in: rect), CGPoint(x: 150, y: 230))
        for pair in PreviewPositionPair.all {
            XCTAssertEqual(PreviewPositionPair.containing(pair.y)?.x, pair.x)
            let value = CGPoint(x: -235, y: 567)
            XCTAssertEqual(pair.coordinates.model(pair.coordinates.canvas(value)), value)
        }
        for parameter in [ImageParameter.shakeX, .shakeY, .shapeWidth, .raysLength, .focusHeight] {
            XCTAssertNil(PreviewPositionPair.containing(parameter))
        }
    }

    func testBaselineMovePreservesAutomationAndAllowsOffscreenPlacement() throws {
        let pair = try XCTUnwrap(PreviewPositionPair.containing(.x))
        var clip = VisualClip(assetID: nil, start: 0, end: 4)
        _ = clip.setKey(.x, at: 0, value: 10)
        _ = clip.setKey(.x, at: 2, value: 30)
        clip.audioModulations[.x] = AudioModulation(source: .beat, amount: 25)
        let curve = try XCTUnwrap(clip.curve(.x))
        var fractional = clip; fractional.setBaseValue(12.5, for: .x)
        XCTAssertEqual(pair.moving(fractional, to: pair.position(in: fractional)), fractional)
        let moved = pair.moving(clip, to: CGPoint(x: 2400, y: -800))
        XCTAssertEqual(moved.baseValue(.x), 2400)
        XCTAssertEqual(moved.baseValue(.y), -800)
        XCTAssertEqual(moved.curve(.x)?.keys.map(\.id), curve.keys.map(\.id))
        XCTAssertEqual(moved.curve(.x)?.keys.map(\.value), curve.keys.map { $0.value + 2400 })
        XCTAssertEqual(moved.audioModulations, clip.audioModulations)
        XCTAssertNil(moved.curve(.y))
        let rays = try XCTUnwrap(PreviewPositionPair.containing(.raysY))
        let effect = VisualClip(assetID: nil, start: 0, end: 4, effects: ImageEffects(radialRays: .init(seed: 42)))
        XCTAssertTrue(rays.enabled(effect.effects!))
        let limited = rays.moving(effect, to: CGPoint(x: -100, y: 9999))
        XCTAssertEqual(limited.baseValue(.raysX), 0)
        XCTAssertEqual(limited.baseValue(.raysY), 1080)
    }

    @MainActor func testVisualTargetPreviewsAndCommitsXYOnce() throws {
        _ = NSApplication.shared
        let editor = VisualEditor(); _ = editor.view
        editor.duration = 10; editor.currentTime = 1
        editor.setAvailable(true)
        var clip = VisualClip(assetID: nil, start: 0, end: 4, effects: ImageEffects(radialRays: .init(seed: 42)))
        _ = clip.setKey(.raysX, at: 0, value: 960)
        var track = VisualTrack(); track.layers[0].clips = [clip]
        editor.commit(track, selectedID: clip.id)
        var commits = 0
        let history = EditHistory()
        history.reset(EditSnapshot(lyrics: LyricsTrack(), visuals: track, settings: SceneSettings()))
        var preview: VisualTrack?
        editor.onChange = { value in
            commits += 1
            history.record(EditSnapshot(lyrics: LyricsTrack(), visuals: value, settings: SceneSettings()))
        }
        editor.onPreview = { preview = $0 }
        let target = try XCTUnwrap(editor.previewHandleTarget(for: .raysX))
        let edit = try XCTUnwrap(target.begin())
        edit.update(CGPoint(x: 1100, y: 650))
        XCTAssertEqual(editor.track, track)
        XCTAssertEqual(preview?.clip(clip.id)?.baseValue(.raysY), 650)
        XCTAssertEqual(target.position(), CGPoint(x: 1100, y: 650))
        edit.finish(true)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.raysX), 1100)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.raysX)?.keys.count, 1)
        XCTAssertEqual(history.undo()?.visuals, track)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo()?.visuals, editor.track)
        let cancellation = try XCTUnwrap(target.begin())
        cancellation.update(CGPoint(x: 300, y: 400)); cancellation.finish(false)
        XCTAssertEqual(commits, 1)
        let unchanged = try XCTUnwrap(target.begin()); unchanged.finish(true)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(target.position(), CGPoint(x: 1100, y: 650))
        editor.currentTime = 5
        XCTAssertTrue(target.isValid()); XCTAssertFalse(target.isVisible())
        editor.currentTime = 2; XCTAssertTrue(target.isVisible())
        var disabled = editor.track
        var updated = try XCTUnwrap(disabled.clip(clip.id)); updated.effects?.radialRays?.isEnabled = false
        disabled = try disabled.updating(updated, layerID: disabled.layers[0].id, duration: 10)
        editor.commit(disabled, selectedID: clip.id)
        XCTAssertFalse(target.isValid())
    }

    @MainActor func testLyricsAndSpectrumTransactions() throws {
        _ = NSApplication.shared
        let lyrics = LyricsEditor(); _ = lyrics.view
        lyrics.setAvailable(true); lyrics.currentTime = 1
        var track = LyricsTrack(); track.clips = [LyricClip(start: 0, end: 3, text: "test")]
        lyrics.load(track)
        var changes = 0
        lyrics.onChange = { _ in changes += 1 }
        let target = try XCTUnwrap(lyrics.previewHandleTarget())
        XCTAssertTrue(target.isVisible())
        let edit = try XCTUnwrap(target.begin())
        edit.update(CGPoint(x: 700, y: 300))
        XCTAssertEqual(lyrics.track, track)
        edit.finish(true)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(lyrics.track.typography.x, 700); XCTAssertEqual(lyrics.track.typography.y, 300)
        let cancel = try XCTUnwrap(target.begin()); cancel.update(.zero); cancel.finish(false)
        XCTAssertEqual(lyrics.track.typography.x, 700); XCTAssertEqual(changes, 1)
        let spectrum = SpectrumEditor(); _ = spectrum.view
        var settings = SceneSettings(); settings.spectrum = true
        spectrum.load(settings); spectrum.setAvailable(true, hasAudio: true)
        var committed: SpectrumSettings?
        var count = 0
        spectrum.onChange = { committed = $0; count += 1 }
        let st = try XCTUnwrap(spectrum.previewHandleTarget())
        let se = try XCTUnwrap(st.begin()); se.update(CGPoint(x: -200, y: 300)); se.finish(true)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(committed?.style.layout.x, -200); XCTAssertEqual(committed?.style.layout.y, 300)
        let sc = try XCTUnwrap(st.begin()); sc.update(.zero); sc.finish(false)
        XCTAssertEqual(count, 1); XCTAssertEqual(st.position(), CGPoint(x: -200, y: 300))
    }

    @MainActor func testFieldLabelFocusAndEscapeSelection() throws {
        _ = NSApplication.shared
        let window = StudioWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let overlay = PreviewHandleView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        let field = DragValueField(frame: CGRect(x: 100, y: 300, width: 100, height: 26))
        let partner = DragValueField(frame: CGRect(x: 220, y: 300, width: 100, height: 26))
        let label = PreviewHandleLabel("X", field: field); label.frame = CGRect(x: 60, y: 300, width: 30, height: 26)
        let ordinary = DragValueField(frame: CGRect(x: 350, y: 300, width: 100, height: 26))
        let target = PreviewHandleTarget(id: "focus", title: "position", isValid: { true }, isVisible: { true }, position: { CGPoint(x: 960, y: 540) }, begin: { nil })
        field.previewHandleProvider = { target }; partner.previewHandleProvider = { target }
        for child in [overlay, field, partner, label, ordinary] { window.contentView!.addSubview(child) }
        window.previewHandles = overlay
        func mouse(_ view: NSView) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(CGPoint(x: 5, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        window.sendEvent(mouse(label))
        XCTAssertEqual(overlay.target?.id, "focus")
        XCTAssertTrue(field.showsPreviewHandle); XCTAssertTrue(partner.showsPreviewHandle)
        field.selectText(nil)
        XCTAssertNotNil(field.currentEditor())
        XCTAssertEqual(overlay.target?.id, "focus")
        window.makeFirstResponder(nil)
        XCTAssertEqual(overlay.target?.id, "focus")
        window.sendEvent(mouse(ordinary))
        XCTAssertNil(overlay.target); XCTAssertFalse(field.showsPreviewHandle)
        partner.selectText(nil)
        XCTAssertEqual(overlay.target?.id, "focus")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        XCTAssertNil(partner.currentEditor()); XCTAssertNotNil(overlay.target)
        window.sendEvent(escape)
        XCTAssertNil(overlay.target)
    }

    @MainActor func testOverlayDragShiftCancelAndOffscreenProxy() throws {
        _ = NSApplication.shared
        let window = StudioWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let overlay = PreviewHandleView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        window.contentView!.addSubview(overlay); window.previewHandles = overlay
        var position = CGPoint(x: 960, y: 540), commits = 0, cancellations = 0
        let target = PreviewHandleTarget(id: "test", title: "test", isValid: { true }, isVisible: { true }, position: { position }, begin: {
            let original = position
            return PreviewHandleEdit(update: { position = $0 }, finish: { commit in
                if commit { commits += 1 } else { position = original; cancellations += 1 }
            })
        })
        overlay.activate(target)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertTrue(overlay.hitTest(CGPoint(x: 240, y: 135)) === overlay)
        if let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my-movie-preview-handle.png"))
        }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: overlay.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseDown(with: event(.leftMouseDown, 240, 135))
        overlay.mouseDragged(with: event(.leftMouseDragged, 260, 140, flags: .shift))
        XCTAssertEqual(position, CGPoint(x: 1040, y: 540))
        overlay.mouseUp(with: event(.leftMouseUp, 260, 140, flags: .shift))
        XCTAssertEqual(commits, 1)
        overlay.mouseDown(with: event(.leftMouseDown, 260, 135))
        overlay.mouseDragged(with: event(.leftMouseDragged, 270, 145))
        XCTAssertTrue(overlay.escape()); XCTAssertEqual(position, CGPoint(x: 1040, y: 540))
        XCTAssertEqual(cancellations, 1); XCTAssertNotNil(overlay.target)
        position = CGPoint(x: -800, y: 540)
        let proxy = try XCTUnwrap(overlay.handlePoint)
        XCTAssertEqual(proxy.x, 14)
        overlay.mouseDown(with: event(.leftMouseDown, proxy.x, proxy.y))
        overlay.mouseUp(with: event(.leftMouseUp, proxy.x + 20, proxy.y))
        XCTAssertEqual(position.x, -720)
        overlay.isPlaying = true; XCTAssertNil(overlay.handlePoint)
        overlay.isPlaying = false; XCTAssertNotNil(overlay.handlePoint)
        overlay.mouseDown(with: event(.leftMouseDown, 100, 50))
        XCTAssertNil(overlay.target)
    }
}
