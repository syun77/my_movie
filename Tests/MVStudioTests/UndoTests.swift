import AppKit
import AVFoundation
import XCTest
@testable import MVStudio

final class UndoTests: XCTestCase {
    @MainActor func testGroupedEditsBranchingAndReset() throws {
        let history = EditHistory()
        let original = history.current
        var value = original
        let group = UUID()
        value.settings.bpm = 130; history.record(value, group: group)
        value.settings.bpm = 140; history.record(value, group: group)
        XCTAssertEqual(history.undo(), original)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(), value)
        var second = value; second.settings.spectrum = false
        history.record(second)
        XCTAssertEqual(history.undo(), value)
        value.settings.beatOffset = 0.5; history.record(value)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo()?.settings.bpm, 140)
        history.reset(original)
        XCTAssertFalse(history.canUndo); XCTAssertFalse(history.canRedo)
        history.record(original)
        XCTAssertFalse(history.canUndo)
        var changed = original; changed.settings.bpm = 180
        history.record(changed, group: group); history.record(original, group: group)
        XCTAssertFalse(history.canUndo, "元の値へ戻る連続操作は履歴を残さない")
    }

    @MainActor func testApplicationUndoRedoRestoresEditorsAndAutosavedProject() async throws {
        let app = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80000)!
        buffer.frameLength = 80000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 80000)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let suite = "UndoTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProjectStorage(defaults: defaults)
        let projectURL = ProjectStorage.projectURL(for: audio)
        let initial = ProjectFile(audioURL: audio, settings: SceneSettings(), projectURL: projectURL)
        try storage.save(initial, to: projectURL)
        let delegate = AppDelegate(storage: storage)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: app))
            delegate.window.close()
        }
        let editor = delegate.placementEditor
        for _ in 0..<250 {
            if editor.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.duration, 10, accuracy: 0.01)
        XCTAssertFalse(delegate.editHistory.canUndo)
        editor.lyrics.perform(NSSelectorFromString("addClip"))
        let added = editor.lyrics.track
        XCTAssertEqual(added.clips.count, 1)
        delegate.undoEdit()
        XCTAssertTrue(editor.lyrics.track.clips.isEmpty)
        XCTAssertTrue(try storage.read(from: projectURL).lyrics.clips.isEmpty)
        delegate.redoEdit()
        XCTAssertEqual(editor.lyrics.track, added)
        XCTAssertEqual(editor.timeline.selectedID, added.clips[0].id)
        XCTAssertEqual(try storage.read(from: projectURL).lyrics, added)

        func find(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0, id) }.first
        }
        let body = try XCTUnwrap(find(editor.lyrics.view, "lyrics.body") as? NSTextView)
        delegate.window.makeFirstResponder(body)
        body.string = "A"; editor.lyrics.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        body.string = "AB"; editor.lyrics.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
        let typed = editor.lyrics.track
        delegate.undoEdit()
        XCTAssertEqual(editor.lyrics.track, added, "本文の入力セッションは1回のUndo")
        XCTAssertEqual(body.string, added.clips[0].text)
        delegate.redoEdit(); XCTAssertEqual(editor.lyrics.track, typed)
        delegate.window.makeFirstResponder(body)
        body.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        delegate.undoEdit(); XCTAssertEqual(editor.lyrics.track, typed, "IME変換中は履歴を変更しない")
        body.unmarkText(); body.string = typed.clips[0].text
        delegate.window.makeFirstResponder(nil)
        let beforeChain = editor.lyrics.track
        editor.lyrics.perform(NSSelectorFromString("addClip"))
        let chained = editor.lyrics.track
        XCTAssertEqual(chained.clips.count, 2)
        XCTAssertEqual(chained.clips[1].predecessorID, chained.clips[0].id)
        delegate.undoEdit(); XCTAssertEqual(editor.lyrics.track, beforeChain)
        delegate.redoEdit(); XCTAssertEqual(editor.lyrics.track, chained)
        let dragged = try chained.dragging(id: chained.clips[0].id, part: .move, delta: 0.5, duration: 10, grid: TimelineSnapGrid())
        editor.timeline.onCommit?(dragged, chained.clips[0].id)
        delegate.undoEdit(); XCTAssertEqual(editor.lyrics.track, chained)
        delegate.redoEdit(); XCTAssertEqual(editor.lyrics.track, dragged)
        editor.lyrics.perform(NSSelectorFromString("removeClip"))
        let removed = editor.lyrics.track
        XCTAssertEqual(removed.clips.count, 1)
        delegate.undoEdit(); XCTAssertEqual(editor.lyrics.track, dragged)
        delegate.redoEdit(); XCTAssertEqual(editor.lyrics.track, removed)

        var images = editor.images.track
        let asset = images.register(url: directory.appendingPathComponent("missing.png"), projectURL: projectURL)
        let result = try images.adding(assetID: asset, at: 1, slot: 2, duration: 10, grid: TimelineSnapGrid())
        editor.images.commit(result.track, selectedID: result.clip.id)
        delegate.undoEdit(); XCTAssertTrue(editor.images.track.clips.isEmpty)
        delegate.redoEdit(); XCTAssertEqual(editor.images.track, result.track)
        XCTAssertEqual(editor.timeline.selectedSlot, 2)
        editor.images.deleteAsset(asset, includingPlacements: true)
        XCTAssertTrue(editor.images.track.assets.isEmpty)
        delegate.undoEdit()
        XCTAssertEqual(editor.images.track, result.track)
        XCTAssertEqual(try storage.read(from: projectURL).images, result.track)
        delegate.redoEdit(); XCTAssertTrue(editor.images.track.clips.isEmpty)

        // Restoring a deleted asset also restores every placement and its reference.
        delegate.undoEdit()
        let replaced = try editor.images.track.replacingAsset(id: asset, url: directory.appendingPathComponent("replacement.png"), projectURL: projectURL)
        editor.images.commit(replaced)
        delegate.undoEdit(); XCTAssertEqual(editor.images.track, result.track)
        delegate.redoEdit(); XCTAssertEqual(editor.images.track, replaced)
        var movedClip = replaced.clips[0]; movedClip.start = 2; movedClip.end = 4
        movedClip.automaticAnimation = .off; movedClip.pulseAmount = 0.2
        _ = movedClip.setKey(.x, at: 2.5, value: 240)
        let moved = try replaced.updating(movedClip, slot: 3, duration: 10)
        editor.images.commit(moved, selectedID: movedClip.id)
        delegate.undoEdit(); XCTAssertEqual(editor.images.track, replaced)
        delegate.redoEdit(); XCTAssertEqual(editor.images.track, moved)

        let studioWindow = try XCTUnwrap(delegate.window as? StudioWindow)
        studioWindow.onBeginInteraction?()
        let width = try XCTUnwrap(editor.lyrics.view.subviewsRecursive.compactMap { $0 as? NSSlider }.first)
        width.doubleValue = 5; editor.lyrics.perform(NSSelectorFromString("changeStyle"))
        width.doubleValue = 7; editor.lyrics.perform(NSSelectorFromString("changeStyle"))
        studioWindow.onEndInteraction?()
        delegate.undoEdit(); XCTAssertEqual(editor.lyrics.track.outlineWidth, typed.outlineWidth)
        delegate.redoEdit(); XCTAssertEqual(width.doubleValue, 7)

        // A failed autosave must not discard the in-memory undo/redo state.
        try FileManager.default.removeItem(at: projectURL)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
        delegate.undoEdit()
        XCTAssertEqual(editor.lyrics.track.outlineWidth, typed.outlineWidth)
        XCTAssertTrue(delegate.editHistory.canRedo)
        try FileManager.default.removeItem(at: projectURL)
        delegate.redoEdit()
        XCTAssertEqual(try storage.read(from: projectURL).lyrics.outlineWidth, 7)

        let font = try XCTUnwrap(find(editor.lyrics.view, "lyrics.font") as? NSPopUpButton)
        let alternate = try XCTUnwrap(font.itemArray.first { ($0.representedObject as? String).map { $0 != LyricsTypography.defaultFontName } == true })
        let fontName = try XCTUnwrap(alternate.representedObject as? String)
        font.select(alternate)
        font.sendAction(font.action, to: font.target)
        let sizeField = try XCTUnwrap(find(editor.lyrics.view, "lyrics.fontSize") as? DragValueField)
        sizeField.stringValue = "80"
        editor.lyrics.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: sizeField))
        XCTAssertEqual(editor.lyrics.track.typography.fontName, fontName)
        XCTAssertEqual(editor.lyrics.track.typography.fontSize, 80)
        XCTAssertEqual(try storage.read(from: projectURL).lyrics.typography, editor.lyrics.track.typography)
        delegate.undoEdit()
        XCTAssertEqual(sizeField.integerValue, 54)
        delegate.undoEdit()
        XCTAssertEqual(font.selectedItem?.representedObject as? String, LyricsTypography.defaultFontName)
        delegate.redoEdit()
        delegate.redoEdit()
        XCTAssertEqual(sizeField.integerValue, 80)
        XCTAssertTrue(sizeField.resetValue())
        XCTAssertEqual(editor.lyrics.track.typography.fontSize, 54)

        editor.restoreTab(.spectrum)
        let spectrum = try XCTUnwrap(delegate.window.contentView?.subviewsRecursive.compactMap { $0 as? NSButton }.first { $0.title == "スペクトラムを表示" })
        spectrum.performClick(nil)
        XCTAssertFalse(delegate.editHistory.current.settings.spectrum)
        delegate.undoEdit()
        XCTAssertEqual(spectrum.state, .on)
        XCTAssertTrue(try storage.read(from: projectURL).settings.spectrum)
        delegate.redoEdit(); XCTAssertEqual(spectrum.state, .off)
        let shape = try XCTUnwrap(find(editor.spectrum.view, "spectrum.shape") as? NSPopUpButton)
        let color = try XCTUnwrap(find(editor.spectrum.view, "spectrum.color") as? NSColorWell)
        let resolution = try XCTUnwrap(find(editor.spectrum.view, "spectrum.resolution") as? NSPopUpButton)
        let widthField = try XCTUnwrap(find(editor.spectrum.view, "spectrum.width") as? DragValueField)
        let gapField = try XCTUnwrap(find(editor.spectrum.view, "spectrum.barGap") as? NSTextField)
        XCTAssertTrue(gapField.isEnabled)
        gapField.stringValue = "60"
        editor.spectrum.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: gapField))
        shape.selectItem(withTitle: "折れ線")
        shape.sendAction(shape.action, to: shape.target)
        XCTAssertFalse(gapField.isEnabled)
        color.color = RGBColor(red: 1, green: 0, blue: 0).nsColor
        color.sendAction(color.action, to: color.target)
        resolution.selectItem(withTitle: "4 帯域")
        resolution.sendAction(resolution.action, to: resolution.target)
        delegate.undoEdit()
        XCTAssertEqual(resolution.titleOfSelectedItem, "32 帯域")
        delegate.redoEdit()
        XCTAssertEqual(resolution.titleOfSelectedItem, "4 帯域")

        func mouse(_ type: NSEvent.EventType, x: Double, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [],
                                            timestamp: 0, windowNumber: studioWindow.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        widthField.mouseDown(with: try mouse(.leftMouseDown, x: 100, clicks: 2))
        let fieldEditor = try XCTUnwrap(widthField.currentEditor() as? NSTextView)
        fieldEditor.string = "960"
        let tabs = try XCTUnwrap(find(editor.inspector, "placement.mode") as? NSSegmentedControl)
        tabs.selectedSegment = 0
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(editor.selectedTab, .lyrics)
        var layout = SpectrumLayout()
        layout.width = 960
        layout.barGap = 60
        let style = SpectrumStyle(shape: .line, color: RGBColor(red: 1, green: 0, blue: 0), resolution: .minimal, layout: layout)
        XCTAssertEqual(try storage.read(from: projectURL).settings.spectrumStyle, style)
        delegate.undoEdit()
        XCTAssertEqual(widthField.integerValue, SpectrumLayout().width)
        delegate.redoEdit()
        XCTAssertEqual(widthField.integerValue, 960)

        let bpm = try XCTUnwrap(find(delegate.window.contentView!, "scene.bpm") as? NSTextField)
        let offset = try XCTUnwrap(find(delegate.window.contentView!, "scene.offset") as? NSTextField)
        bpm.stringValue = "160"; delegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: bpm))
        offset.stringValue = "0.25"; delegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: offset))
        delegate.undoEdit(); XCTAssertEqual(editor.snapGrid.origin, 0)
        delegate.undoEdit(); XCTAssertEqual(bpm.doubleValue, 120)
        delegate.redoEdit(); XCTAssertEqual(bpm.doubleValue, 160)
        delegate.redoEdit(); XCTAssertEqual(offset.doubleValue, 0.25)
        XCTAssertEqual(try storage.read(from: projectURL).settings.beatOffset, 0.25)

        XCTAssertEqual(try storage.read(from: projectURL).settings.spectrumStyle, style)

        editor.restoreTab(.spectrum)
        let preview = try XCTUnwrap(delegate.window.contentView?.subviewsRecursive.compactMap { $0 as? PreviewView }.first)
        widthField.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        widthField.mouseDragged(with: try mouse(.leftMouseDragged, x: 80))
        XCTAssertEqual(widthField.integerValue, 940)
        XCTAssertEqual(preview.spectrumLayoutPreview?.width, 940)
        XCTAssertEqual(try storage.read(from: projectURL).settings.spectrumStyle.layout.width, 960)
        XCTAssertTrue(studioWindow.cancelNumberDrags())
        widthField.mouseUp(with: try mouse(.leftMouseUp, x: 80))
        XCTAssertNil(preview.spectrumLayoutPreview)
        XCTAssertEqual(widthField.integerValue, 960)

        widthField.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        widthField.mouseDragged(with: try mouse(.leftMouseDragged, x: 130))
        widthField.mouseUp(with: try mouse(.leftMouseUp, x: 140))
        XCTAssertEqual(try storage.read(from: projectURL).settings.spectrumStyle.layout.width, 1000)
        delegate.undoEdit()
        XCTAssertEqual(widthField.integerValue, 960)
        delegate.redoEdit()
        XCTAssertEqual(widthField.integerValue, 1000)
        XCTAssertTrue(widthField.resetValue())
        XCTAssertEqual(try storage.read(from: projectURL).settings.spectrumStyle.layout.width, SpectrumLayout().width)
        delegate.undoEdit()
        delegate.undoEdit()

        editor.restoreTab(.images)
        editor.timeline.onImageSelect?(movedClip.id, 3)
        let disclosure = try XCTUnwrap(find(editor.images.view, "images.effects") as? NSButton)
        disclosure.performClick(nil)
        let addEffect = try XCTUnwrap(find(editor.images.view, "images.effects.add") as? NSPopUpButton)
        let addBlur = try XCTUnwrap(addEffect.item(withTitle: "ガウスブラー"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(addBlur.action), to: addBlur.target, from: addBlur))
        XCTAssertFalse(addBlur.isEnabled)
        XCTAssertEqual(try storage.read(from: projectURL).images.clip(movedClip.id)?.effects?.blur?.radius, 8)
        let blurField = try XCTUnwrap(editor.images.view.subviewsRecursive.compactMap { $0 as? DragValueField }
            .first { $0.isEnabled && $0.accessibilityLabel() == "半径 px" })
        blurField.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        blurField.mouseDragged(with: try mouse(.leftMouseDragged, x: 111))
        XCTAssertEqual(blurField.doubleValue, 19)
        XCTAssertEqual(editor.images.track.clip(movedClip.id)?.effects?.blur?.radius, 8)
        XCTAssertTrue(studioWindow.cancelNumberDrags())
        XCTAssertEqual(blurField.doubleValue, 8)
        blurField.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        blurField.mouseDragged(with: try mouse(.leftMouseDragged, x: 111))
        blurField.mouseUp(with: try mouse(.leftMouseUp, x: 111))
        XCTAssertEqual(try storage.read(from: projectURL).images.clip(movedClip.id)?.effects?.blur?.radius, 19)
        delegate.undoEdit()
        XCTAssertEqual(blurField.doubleValue, 8)
        delegate.redoEdit()
        XCTAssertEqual(blurField.doubleValue, 19)
        delegate.undoEdit()
        delegate.undoEdit()
        XCTAssertNil(editor.images.track.clip(movedClip.id)?.effects)

        let addEmbers = try XCTUnwrap(addEffect.item(withTitle: "舞い上がる火の粉"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(addEmbers.action), to: addEmbers.target, from: addEmbers))
        let wind = try XCTUnwrap(editor.images.view.subviewsRecursive.compactMap { $0 as? DragValueField }
            .first { $0.isEnabled && $0.accessibilityLabel() == "横風 px/秒" })
        wind.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        wind.mouseDragged(with: try mouse(.leftMouseDragged, x: 70))
        wind.mouseUp(with: try mouse(.leftMouseUp, x: 70))
        XCTAssertEqual(try storage.read(from: projectURL).images.clip(movedClip.id)?.effects?.embers?.wind, -6)
        delegate.undoEdit()
        XCTAssertEqual(wind.doubleValue, 24)
        delegate.redoEdit()
        XCTAssertEqual(wind.doubleValue, -6)
        delegate.undoEdit()
        delegate.undoEdit()
        XCTAssertNil(editor.images.track.clip(movedClip.id)?.effects)

        let addParticles = try XCTUnwrap(addEffect.item(withTitle: "光の粒子"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(addParticles.action), to: addParticles.target, from: addParticles))
        let addSource = try XCTUnwrap(editor.images.view.subviewsRecursive.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "発生源を追加" })
        let removeSource = try XCTUnwrap(editor.images.view.subviewsRecursive.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "発生源を削除" })
        let sourceX = try XCTUnwrap(editor.images.view.subviewsRecursive.compactMap { $0 as? DragValueField }
            .first { $0.accessibilityLabel() == "発生源のX" })
        XCTAssertFalse(removeSource.isEnabled)
        addSource.performClick(nil)
        XCTAssertEqual(sourceX.doubleValue, 1440)
        sourceX.mouseDown(with: try mouse(.leftMouseDown, x: 100))
        sourceX.mouseDragged(with: try mouse(.leftMouseDragged, x: 120))
        sourceX.mouseUp(with: try mouse(.leftMouseUp, x: 120))
        XCTAssertEqual(try storage.read(from: projectURL).images.clip(movedClip.id)?.effects?.particles?.emitters.map(\.x), [960, 1460])
        removeSource.performClick(nil)
        XCTAssertEqual(try storage.read(from: projectURL).images.clip(movedClip.id)?.effects?.particles?.emitters.count, 1)
        delegate.undoEdit()
        XCTAssertEqual(try storage.read(from: projectURL).images.clip(movedClip.id)?.effects?.particles?.emitters.map(\.x), [960, 1460])
        delegate.undoEdit()
        delegate.undoEdit()
        delegate.undoEdit()
        XCTAssertNil(editor.images.track.clip(movedClip.id)?.effects)

        editor.images.openManager()
        XCTAssertNotNil(editor.images.managerWindow?.sheetParent)
        delegate.undoEdit(); XCTAssertEqual(offset.doubleValue, 0, "画像管理シートでも共通Undoを利用する")
        delegate.redoEdit(); XCTAssertEqual(offset.doubleValue, 0.25)
        if let sheet = editor.images.managerWindow { delegate.window.endSheet(sheet) }

        func applyPreset<Settings: PresetSettings>(_ value: Settings, in view: NSView, id: String) throws {
            let button = try XCTUnwrap(find(view, id) as? NSPopUpButton)
            XCTAssertTrue(button.isEnabled)
            let target = try XCTUnwrap(button.item(at: 1)?.target)
            let action = NSSelectorFromString("applyPreset:")
            let item = NSMenuItem(title: "テスト用プリセット", action: action, keyEquivalent: "")
            item.representedObject = NamedPreset(name: item.title, settings: value)
            XCTAssertTrue(NSApp.sendAction(action, to: target, from: item))
        }

        editor.restoreTab(.lyrics)
        let previousLyrics = editor.lyrics.track
        let selectedClip = editor.timeline.selectedID
        let preset = LyricsStyle(outlineWidth: 7, outlineColor: RGBColor(red: 0, green: 1, blue: 0),
                                 typography: LyricsTypography(fontSize: 100, x: 560, y: 640))
        try applyPreset(preset, in: editor.lyrics.view, id: "lyrics.presets")
        XCTAssertEqual(editor.lyrics.track.style, preset)
        XCTAssertEqual(editor.lyrics.track.clips, previousLyrics.clips)
        XCTAssertEqual(editor.timeline.selectedID, selectedClip)
        XCTAssertEqual(try storage.read(from: projectURL).lyrics, editor.lyrics.track)
        delegate.undoEdit()
        XCTAssertEqual(editor.lyrics.track, previousLyrics)
        delegate.redoEdit()
        XCTAssertEqual(editor.lyrics.track.style, preset)

        editor.restoreTab(.spectrum)
        let previousSettings = try storage.read(from: projectURL).settings
        let spectrumPreset = SpectrumSettings(shown: false, style: SpectrumStyle(layout: SpectrumLayout(width: 123)))
        try applyPreset(spectrumPreset, in: editor.spectrum.view, id: "spectrum.presets")
        XCTAssertEqual(widthField.integerValue, 123)
        XCTAssertFalse(preview.settings.spectrum)
        XCTAssertEqual(preview.settings.spectrumStyle, spectrumPreset.style)
        XCTAssertEqual(preview.settings.bpm, previousSettings.bpm)
        XCTAssertEqual(preview.settings.beatOffset, previousSettings.beatOffset)
        XCTAssertEqual(try storage.read(from: projectURL).settings, preview.settings)
        delegate.undoEdit()
        XCTAssertEqual(preview.settings, previousSettings)
        delegate.redoEdit()
        XCTAssertEqual(preview.settings.spectrumStyle, spectrumPreset.style)
    }

    @MainActor func testKeyboardRoutesToProjectHistoryWhileTyping() throws {
        _ = NSApplication.shared
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = NSTextView(); window.contentView = text; window.makeFirstResponder(text)
        var actions: [Bool] = []
        window.onHistoryAction = { actions.append($0) }
        for flags: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(actions, [false, true])
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] { [self] + subviews.flatMap(\.subviewsRecursive) }
}
