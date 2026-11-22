import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate, NSMenuItemValidation {
    private(set) var window: NSWindow!
    let editHistory = EditHistory()
    private var textHistoryResponder: ObjectIdentifier?
    private var textHistoryGroup: UUID?
    private var colorHistoryGroup: UUID?
    private var mouseHistoryGroup: UUID?
    private let preview = PreviewView()
    private let status = NSTextField(labelWithString: "画像と音声を読み込んでください")
    private let audioName = NSTextField(labelWithString: "音声: 未選択")
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let bpm = DragValueField(frame: .zero)
    private let offset = DragValueField(frame: .zero)
    private let play = NSButton(title: "再生", target: nil, action: nil)
    private let manageAssets = NSButton(title: "素材管理…", target: nil, action: nil)
    private let export = NSButton(title: "MP4を書き出す", target: nil, action: nil)
    private let cancel = NSButton(title: "キャンセル", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var player: AVAudioPlayer?
    private var audioURL: URL?
    private var projectURL: URL?
    private let timelineDisplaySettings: TimelineDisplaySettings
    private let storage: ProjectStorage
    let placementEditor = PlacementEditor()
    private var lyricsEditor: LyricsEditor { placementEditor.lyrics }
    private let previewFrames = VisualFrameProvider()
    private var pendingFrame: FrameRequest?
    private var playbackPreparation: Task<Void, Never>?
    private var wasPlaying = false
    private var playbackRequestID = UUID()
    private struct FrameRequest {
        let track: VisualTrack
        let projectURL: URL
        let time: Double
        let revision: Int
        let key: PreviewKey
    }
    private var previewFrameTask: Task<Void, Never>?
    private var previewRevision = 0
    private var transientPreparation: Task<Void, Never>?
    private var transientRevision = UUID()
    private var visualTrack = VisualTrack()
    private var previewTrack = VisualTrack()

    private var timer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var cancellation: ExportCancellation?
    private var busy = false
    private var imageProcessing = false
    private var controls = [NSControl]()

    init(storage: ProjectStorage = ProjectStorage(), timelineDisplaySettings: TimelineDisplaySettings = TimelineDisplaySettings()) {
        self.timelineDisplaySettings = timelineDisplaySettings
        self.storage = storage
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let studioWindow = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window = studioWindow
        studioWindow.clipEditor = placementEditor
        studioWindow.previewHandles = preview.handles
        placementEditor.onTabChange = { [weak self] in self?.preview.handles.clear() }
        placementEditor.visuals.onColorSession = { [weak self] group in
            self?.colorHistoryGroup = group
        }
        studioWindow.onBeginInteraction = { [weak self] in self?.endHistoryGroup(); self?.mouseHistoryGroup = UUID() }
        studioWindow.onEndInteraction = { [weak self] in self?.mouseHistoryGroup = nil; self?.endHistoryGroup() }
        studioWindow.onEscapeInteraction = { [weak self] in self?.placementEditor.visuals.cancelValueDrag() ?? false }
        studioWindow.onEscapeText = { [weak self] text in self?.placementEditor.visuals.cancelAnimationInput(text) ?? false }
        studioWindow.onHistoryAction = { [weak self] redo in self?.performHistoryAction(redo: redo) }

        studioWindow.onTogglePlayback = { [weak self] in
            guard let self, self.play.isEnabled else { return }
            self.togglePlay()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "MV Studio"
        window.contentMinSize = NSSize(width: 1000, height: 680)
        let audioButton = button("音声を選択…", #selector(importAudio))
        let audioSelection = row([audioButton])
        audioName.lineBreakMode = .byTruncatingMiddle
        audioName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bpm.widthAnchor.constraint(equalToConstant: 88).isActive = true
        offset.widthAnchor.constraint(equalToConstant: 88).isActive = true
        bpm.identifier = NSUserInterfaceItemIdentifier("scene.bpm"); offset.identifier = NSUserInterfaceItemIdentifier("scene.offset")
        bpm.delegate = self; offset.delegate = self
        bpm.stringValue = "120"; offset.stringValue = "0"
        bpm.bindNumber(current: { [weak self] in self?.preview.settings.bpm }, initial: { SceneSettings().bpm },
                       normalize: { min(300, max(20, $0)) }, commit: { [weak self] _ in self?.updateSettings() })
        offset.bindNumber(step: 0.01, current: { [weak self] in self?.preview.settings.beatOffset },
                          initial: { SceneSettings().beatOffset }, normalize: { max(0, $0) },
                          commit: { [weak self] _ in self?.updateSettings() })
        for control in [bpm, offset] { control.target = self; control.action = #selector(updateSettings) }
        let timingControls = row([NSTextField(labelWithString: "BPM"), bpm, NSTextField(labelWithString: "拍開始（秒）"), offset])
        play.target = self; play.action = #selector(togglePlay)
        export.target = self; export.action = #selector(exportVideo)
        cancel.target = self; cancel.action = #selector(cancelWork)
        cancel.isHidden = true
        seek.target = self; seek.action = #selector(scrubWholeSong)
        seek.isContinuous = true
        seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transport = row([seek, play, timeLabel])
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let outputFormat = NSTextField(labelWithString: "\(VideoExporter.width) × \(VideoExporter.height) · \(VideoExporter.fps)fps · H.264 / AAC")
        manageAssets.target = placementEditor.visuals
        manageAssets.action = #selector(VisualEditor.openManager)
        let projectSettings = placementEditor.projectSettings
        projectSettings.orientation = .vertical
        projectSettings.alignment = .leading
        projectSettings.spacing = 12
        let sections = [
            InspectorSection("音声", id: "project.audio", rows: [audioSelection, audioName]),
            InspectorSection("音楽同期", id: "project.timing", rows: [timingControls]),
            InspectorSection("素材", id: "project.assets", rows: [row([manageAssets])]),
            InspectorSection("動画出力", id: "project.output", rows: [outputFormat, row([export])])
        ]
        for section in sections {
            projectSettings.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: projectSettings.widthAnchor).isActive = true
        }
        let activityControls = row([progress, cancel])
        let timeline = placementEditor.view
        placementEditor.visibleSpan = timelineDisplaySettings.visibleSpan
        placementEditor.snapGrid.division = timelineDisplaySettings.snapDivision
        placementEditor.onSnapDivisionChange = { [weak self] value in self?.timelineDisplaySettings.snapDivision = value }
        placementEditor.showsWholeSong = timelineDisplaySettings.showsWholeSong
        placementEditor.onWholeSongChange = { [weak self] value in self?.timelineDisplaySettings.showsWholeSong = value }
        placementEditor.restoreTab(timelineDisplaySettings.visualMode ? .visuals : .lyrics)
        preview.showsBelowMaskGuide = placementEditor.visuals.showsBelowMaskGuide
        placementEditor.visuals.onBelowMaskGuideChange = { [weak self] in self?.preview.showsBelowMaskGuide = $0 }
        preview.showsMaskGuide = timelineDisplaySettings.visualMode
        placementEditor.onModeChange = { [weak self] value in
            self?.timelineDisplaySettings.visualMode = value
            self?.preview.showsMaskGuide = value
        }
        placementEditor.onError = { [weak self] value in self?.status.stringValue = value }
        placementEditor.onVisibleSpanChange = { [weak self] value in
            self?.timelineDisplaySettings.visibleSpan = value
        }
        placementEditor.spectrum.onLayoutPreview = { [weak self] layout in
            self?.preview.spectrumLayoutPreview = layout
            self?.preview.invalidateFrame()
        }
        placementEditor.spectrum.onEndTextEditing = { [weak self] in self?.finishTextHistoryGroup() }
        placementEditor.spectrum.onChange = { [weak self] value in
            guard let self else { return }
            var settings = self.preview.settings
            settings.spectrum = value.shown
            settings.spectrumStyle = value.style
            guard settings != self.preview.settings else { return }
            self.recordEdit(settings: settings)
            self.preview.settings = settings
            self.preview.invalidateFrame()
            _ = self.saveProject()
        }
        lyricsEditor.onBeginTextEditing = { [weak self] in self?.endHistoryGroup() }
        lyricsEditor.onEndTextEditing = { [weak self] in self?.finishTextHistoryGroup() }
        placementEditor.visuals.onBeginTextEditing = { [weak self] in self?.endHistoryGroup() }
        placementEditor.visuals.onEndTextEditing = { [weak self] in self?.finishTextHistoryGroup() }
        lyricsEditor.onChange = { [weak self] value in
            guard let self else { return }
            self.recordEdit(lyrics: value); self.stopPlayback(); self.preview.lyrics = value; self.preview.invalidateFrame(); _ = self.saveProject()
        }
        lyricsEditor.onPreview = { [weak self] value in
            self?.preview.lyrics = value; self?.preview.invalidateFrame()
        }
        lyricsEditor.onCapturePlaybackTime = { [weak self] in
            guard let self else { return 0 }
            self.stopPlayback()
            let time = self.player?.currentTime ?? self.preview.time
            self.seek.doubleValue = time; self.scrub()
            return time
        }
        lyricsEditor.onSeek = { [weak self] time in
            guard let self else { return }
            self.stopPlayback(); self.seek.doubleValue = time; self.scrub()
        }
        placementEditor.visuals.onSelectionChange = { [weak self] id in
            self?.preview.guideClipID = id
            self?.preview.handles.refresh()
        }
        placementEditor.visuals.onProcessing = { [weak self] value in self?.imageProcessing = value; self?.refreshControls() }
        placementEditor.visuals.onAssetsReload = { [weak self] in
            guard let self else { return }
            self.preview.handles.clear()
            self.lastPreviewKey = nil; self.displayedPreviewKey = nil; self.previewRevision += 1
            Task { await self.previewFrames.invalidate(); self.refreshPreviewFrames() }
        }
        placementEditor.visuals.onBeginEdit = { [weak self] in _ = self?.lyricsEditor.onCapturePlaybackTime?() }
        placementEditor.visuals.onSeek = { [weak self] time in self?.lyricsEditor.onSeek?(time) }
        placementEditor.visuals.onChange = { [weak self] value in
            guard let self else { return }
            self.recordEdit(visuals: value); self.stopPlayback(); self.visualTrack = value; self.previewTrack = value; self.prepareTransients(); self.refreshPreviewFrames(); self.refreshControls(); _ = self.saveProject()
        }
        placementEditor.visuals.onPreview = { [weak self] value in self?.previewTrack = value; self?.refreshPreviewFrames() }
        installLayout(activity: activityControls, transport: transport, timeline: timeline)
        controls = [audioButton, bpm, offset, play, seek, export]
        refreshControls()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        editHistory.reset(EditSnapshot(lyrics: preview.lyrics, visuals: visualTrack, settings: preview.settings))
        if let url = storage.lastProjectURL { openProject(at: url) }
    }

    private func installLayout(activity: NSView, transport: NSView, timeline: NSView) {
        let content = NSView()
        window.contentView = content

        let workspace = NSView()
        let inspector = placementEditor.inspector
        for child in [preview, inspector] {
            child.translatesAutoresizingMaskIntoConstraints = false
            workspace.addSubview(child)
        }

        let minimumPreviewHeight: CGFloat = 100
        let divider = TimelineDivider()
        divider.onDrag = { [weak self, weak content] height in
            guard let self, !self.busy, let content else { return }
            let timelineHeight = self.placementEditor.timeline.frame.height
            let maximumHeight = timelineHeight + max(0, self.preview.frame.height - minimumPreviewHeight)
            self.placementEditor.resizeTimeline(to: min(height, maximumHeight))
            content.layoutSubtreeIfNeeded()
        }
        divider.onCommit = { [weak self] initialHeight in
            guard let self, !self.busy else { return }
            self.placementEditor.commitTimelineHeight(from: initialHeight)
        }
        placementEditor.onTimelineHeightsCommit = { [weak self] in _ = self?.saveProject() }
        divider.timelineHeight = { [weak self] in
            guard let self, !self.busy else { return nil }
            return self.placementEditor.timeline.frame.height
        }

        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let root = NSStackView(views: [workspace, divider, transport, timeline, row([status, activity])])
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 12
        root.setCustomSpacing(4, after: workspace)
        root.setCustomSpacing(4, after: divider)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 9),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumPreviewHeight),
            preview.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            preview.topAnchor.constraint(equalTo: workspace.topAnchor),
            preview.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -20),
            preview.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            inspector.topAnchor.constraint(equalTo: workspace.topAnchor),
            inspector.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            inspector.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 450)
        ])
    }

    private func row(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.spacing = 12; stack.alignment = .centerY; return stack }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); app.addItem(withTitle: "MV Studioを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = app
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "編集")
        let undo = edit.addItem(withTitle: "取り消す", action: #selector(undoEdit), keyEquivalent: "z"); undo.target = self
        let redo = edit.addItem(withTitle: "やり直す", action: #selector(redoEdit), keyEquivalent: "z"); redo.target = self; redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [("カット", "cut:", "x"), ("コピー", "copy:", "c"), ("ペースト", "paste:", "v"), ("すべて選択", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        edit.addItem(withTitle: "クリップを複製", action: #selector(StudioWindow.duplicateClip(_:)), keyEquivalent: "d")
        editItem.submenu = edit; NSApp.mainMenu = menu
    }
    private func choose(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    @objc private func importAudio() {
        guard placementEditor.finishEditing() else { return }
        guard saveProject(), let url = choose([.audio]) else { return }
        let project = ProjectStorage.projectURL(for: url)
        if FileManager.default.fileExists(atPath: project.path) {
            openProject(at: project)
        } else {
            loadAudio(at: url, projectURL: project, restoring: nil)
        }
    }
    func openProject(at url: URL) {
        do {
            let result = try storage.readForOpening(from: url)
            loadAudio(at: result.project.audio.resolve(projectURL: url), projectURL: url, restoring: result)
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText += "\n既存プロジェクトを残して新しく始める場合は、バックアップを作成してください。"
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "バックアップして新規作成")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            do {
                let backup = url.appendingPathExtension(UUID().uuidString + ".backup")
                try FileManager.default.moveItem(at: url, to: backup)
                let audio = url.deletingPathExtension()
                loadAudio(at: audio, projectURL: url, restoring: nil)
            } catch { showError(error) }
        }
    }
    private func loadAudio(at url: URL, projectURL: URL, restoring readResult: ProjectReadResult?) {
        let project = readResult?.project
        stopPlayback(); setBusy(true)
        status.stringValue = readResult?.needsMigration == true
            ? "演出の外観が変わる場合があります。原本をバックアップしてチェーンへ変換します。音声を解析中…"
            : "音声を解析しています…"
        progress.isIndeterminate = true; progress.startAnimation(nil)
        analysisTask = Task {
            do {
                let task = Task.detached { try AudioAnalyzer.analyze(url: url) }
                let features = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                let loaded = try AVAudioPlayer(contentsOf: url); loaded.prepareToPlay()
                try project?.lyrics.validate(duration: features.duration)
                try project?.visuals.validate(duration: features.duration)
                let backup = try readResult.flatMap { try storage.commitMigration($0) }
                await previewFrames.invalidate()
                preview.handles.clear()
                player = loaded; audioURL = url; preview.features = features; preview.time = 0
                self.projectURL = projectURL
                lyricsEditor.clearPresetSelection()
                placementEditor.spectrum.clearPresetSelection()
                if let project {
                    restoreSceneSettings(project.settings)
                } else if let filenameBPM = AudioFilename.bpm(in: url) {
                    var settings = preview.settings
                    settings.bpm = filenameBPM
                    restoreSceneSettings(settings)
                }
                placementEditor.restoreTimelineHeights(project?.timelineHeights ?? TimelineHeights())
                preview.lyrics = project?.lyrics ?? LyricsTrack()
                visualTrack = project?.visuals ?? VisualTrack(); previewTrack = visualTrack
                placementEditor.visuals.load(visualTrack, projectURL: projectURL)
                lyricsEditor.load(preview.lyrics); placementEditor.duration = features.duration
                seek.maxValue = features.duration; seek.doubleValue = 0; updateTime()
                audioName.stringValue = "音声: " + url.lastPathComponent
                previewRevision += 1; lastPreviewKey = nil; displayedPreviewKey = nil; preview.visuals = []
                editHistory.reset(EditSnapshot(lyrics: preview.lyrics, visuals: visualTrack, settings: preview.settings)); endHistoryGroup()
                prepareTransients()
                if let backup, let readResult {
                    status.stringValue = "演出の外観が変わる場合があります。v\(readResult.sourceVersion)→v\(ProjectFile.currentVersion)変換済み（原本バックアップあり）"
                    status.toolTip = readResult.changes.joined(separator: "、") + "\n" + backup.path
                } else { _ = saveProject() }
                refreshPreviewFrames()
            } catch is CancellationError { status.stringValue = "解析をキャンセルしました。" }
            catch { showError(error) }
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 0; setBusy(false); preview.invalidateFrame()
        }
    }
    @discardableResult private func saveProject() -> Bool {
        guard let audioURL, let projectURL else { return true }
        do {
            try storage.save(ProjectFile(audioURL: audioURL, visuals: visualTrack, settings: preview.settings, lyrics: preview.lyrics,
                                         timelineHeights: placementEditor.timelineHeights, projectURL: projectURL), to: projectURL)
            status.stringValue = "自動保存済み: " + projectURL.lastPathComponent
            return true
        } catch {
            status.stringValue = "自動保存に失敗しました: " + error.localizedDescription
            return false
        }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { endHistoryGroup() }
    func controlTextDidEndEditing(_ obj: Notification) { updateSettings(); finishTextHistoryGroup() }
    @objc private func updateSettings() {
        readSceneSettings()
        _ = saveProject()
    }
    private func readSceneSettings() {
        let bpmValue = Double(bpm.stringValue) ?? 120
        let offsetValue = Double(offset.stringValue) ?? 0
        var settings = preview.settings
        settings.bpm = bpmValue.isFinite ? min(300, max(20, bpmValue)) : 120
        settings.beatOffset = offsetValue.isFinite ? max(0, offsetValue) : 0
        recordEdit(settings: settings)
        preview.settings = settings
        updateSnapGrid(for: settings)
        bpm.stringValue = String(format: "%.1f", preview.settings.bpm)
        offset.stringValue = String(format: "%.2f", preview.settings.beatOffset)
        preview.invalidateFrame()
    }
    private func restoreSceneSettings(_ settings: SceneSettings) {
        preview.settings = settings
        bpm.doubleValue = settings.bpm
        offset.doubleValue = settings.beatOffset
        placementEditor.spectrum.load(settings)
        updateSnapGrid(for: settings)
    }

    private func updateSnapGrid(for settings: SceneSettings) {
        var grid = placementEditor.snapGrid
        grid.bpm = settings.bpm
        grid.origin = settings.beatOffset
        placementEditor.snapGrid = grid
        placementEditor.timeline.sceneSettings = settings
        placementEditor.visuals.musicEditor.settings = settings
        placementEditor.visuals.lfoEditor.settings = settings
    }

    private func endHistoryGroup() {
        textHistoryResponder = nil; textHistoryGroup = nil
    }
    private func finishTextHistoryGroup() {
        endHistoryGroup()
        if mouseHistoryGroup != nil { mouseHistoryGroup = UUID() }
    }
    private func recordEdit(lyrics: LyricsTrack? = nil, visuals: VisualTrack? = nil, settings: SceneSettings? = nil) {
        if let text = window?.firstResponder as? NSTextView, text.isEditable {
            let identity = ObjectIdentifier(text)
            if textHistoryResponder != identity { textHistoryGroup = UUID(); textHistoryResponder = identity }
        } else { endHistoryGroup() }
        var value = editHistory.current
        if let lyrics { value.lyrics = lyrics }
        if let visuals { value.visuals = visuals }
        if let settings { value.settings = settings }
        editHistory.record(value, group: colorHistoryGroup ?? mouseHistoryGroup ?? textHistoryGroup)
    }
    private var historyIsAvailable: Bool {
        guard let window, !busy, !imageProcessing, NSApp.modalWindow == nil else { return false }
        if let sheet = window.attachedSheet { return sheet === placementEditor.visuals.managerWindow }
        return true
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoEdit) { return historyIsAvailable && editHistory.canUndo }
        if menuItem.action == #selector(redoEdit) { return historyIsAvailable && editHistory.canRedo }
        return true
    }
    @objc func undoEdit() { performHistoryAction(redo: false) }
    @objc func redoEdit() { performHistoryAction(redo: true) }
    private func performHistoryAction(redo: Bool) {
        preview.handles.cancelDrag()
        guard historyIsAvailable else { return }
        if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { NSSound.beep(); return }
        (window as? StudioWindow)?.cancelNumberDrags()
        placementEditor.cancelTimelineEdit()
        guard window.makeFirstResponder(nil) else { return }
        endHistoryGroup()
        guard let value = redo ? editHistory.redo() : editHistory.undo() else { return }
        stopPlayback()
        restoreSceneSettings(value.settings); preview.lyrics = value.lyrics
        visualTrack = value.visuals; previewTrack = value.visuals
        lyricsEditor.restore(value.lyrics); placementEditor.visuals.restore(value.visuals)
        prepareTransients()
        lastPreviewKey = nil; refreshPreviewFrames(); refreshControls(); preview.invalidateFrame()
        _ = saveProject()
    }
    @objc private func togglePlay() {
        guard let player else { return }
        if player.isPlaying || playbackPreparation != nil { stopPlayback(); return }
        preview.handles.cancelDrag()
        placementEditor.timeline.followPlayhead()
        if player.currentTime >= player.duration - 0.01 { player.currentTime = 0 }
        preview.time = player.currentTime
        updateTime()
        preview.handles.isPlaying = true
        let revision = previewRevision
        let requestID = UUID(); playbackRequestID = requestID
        play.title = "準備中…"
        playbackPreparation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.playbackRequestID == requestID {
                    self.playbackPreparation = nil
                    self.play.title = player.isPlaying ? "一時停止" : "再生"
                }
            }
            // The preview worker coalesces requests while paused; begin audio after its first frame.
            while self.previewFrameTask != nil {
                do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
                guard !Task.isCancelled, self.previewRevision == revision else { return }
            }
            guard !Task.isCancelled, self.previewRevision == revision else { return }
            self.playbackPreparation = nil
            if self.preview.frameFailure { self.play.title = "再生"; return }
            player.play(); self.wasPlaying = true; self.tick()
        }
    }
    private func stopPlayback() {
        preview.handles.isPlaying = false
        playbackRequestID = UUID(); playbackPreparation?.cancel(); playbackPreparation = nil
        if let player, player.isPlaying { preview.time = player.currentTime; seek.doubleValue = preview.time }
        player?.pause(); wasPlaying = false; play.title = "再生"
    }
    @objc private func scrubWholeSong() {
        placementEditor.timeline.followPlayhead()
        scrub()
    }
    private func scrub() {
        preview.handles.cancelDrag()
        previewRevision += 1; lastPreviewKey = nil
        player?.currentTime = seek.doubleValue; preview.time = seek.doubleValue
        updateTime()
    }
    private func tick() {
        guard let player, !busy else { return }
        if player.isPlaying {
            preview.time = player.currentTime; seek.doubleValue = preview.time
        } else if wasPlaying {
            preview.time = player.duration; seek.doubleValue = player.duration; wasPlaying = false
        }
        if playbackPreparation == nil { play.title = player.isPlaying ? "一時停止" : "再生" }
        updateTime()
    }
    private func updateTime() {
        preview.handles.isPlaying = player?.isPlaying == true || playbackPreparation != nil
        placementEditor.currentTime = preview.time
        preview.handles.refresh()
        refreshPreviewFrames()
        func format(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
        timeLabel.stringValue = "\(format(preview.time)) / \(format(preview.features?.duration ?? 0))"
    }
    private struct PreviewKey: Equatable {
        let projectURL: URL
        let clips: [VisualClip]
        let layers: [UUID]
        let assets: [VisualAsset]
    }
    private var lastPreviewKey: PreviewKey?
    private var displayedPreviewKey: PreviewKey?
    private func refreshPreviewFrames() {
        guard let projectURL else { return }
        let track = previewTrack, time = preview.time
        let active = track.active(at: time)
        let key = PreviewKey(projectURL: projectURL, clips: active, layers: track.layers.map(\.id), assets: active.compactMap { track.asset($0.assetID) })
        let dynamic = active.contains { $0.content.sourceIn != nil }
        if key != lastPreviewKey {
            previewRevision += 1; lastPreviewKey = key
            if let displayedPreviewKey, displayedPreviewKey.projectURL == key.projectURL,
               displayedPreviewKey.assets == key.assets,
               let layers = PreviewFrameReuse.stills(preview.visuals, track: track, time: time) {
                pendingFrame = nil
                preview.visuals = layers; preview.renderedTime = time
                preview.frameFailure = false; preview.frameStatus = nil
                preview.invalidateFrame()
                return
            }
            if displayedPreviewKey?.projectURL != key.projectURL || active.isEmpty {
                preview.visuals = []; preview.renderedTime = time
                preview.invalidateFrame()
            }
            preview.frameStatus = dynamic && preview.visuals.isEmpty ? "映像を準備しています…" : nil
        } else if preview.frameFailure { return
        } else if previewFrameTask == nil, !dynamic || (preview.renderedTime == time && !preview.visuals.isEmpty) {
            preview.renderedTime = time; preview.invalidateFrame(); return
        }
        pendingFrame = FrameRequest(track: track, projectURL: projectURL, time: time, revision: previewRevision, key: key)
        guard previewFrameTask == nil else { return }
        previewFrameTask = Task { [weak self] in
            guard let self else { return }
            defer { self.previewFrameTask = nil }
            while let request = self.pendingFrame {
                self.pendingFrame = nil
                do {
                    let layers = try await self.previewFrames.layers(track: request.track, projectURL: request.projectURL, time: request.time, allowMissingImages: true)
                    guard !Task.isCancelled, request.revision == self.previewRevision else { continue }
                    let lag = abs(self.preview.time - request.time)
                    if self.player?.isPlaying == true, lag > 0.25 {
                        self.stopPlayback()
                        self.preview.frameFailure = true; self.preview.frameStatus = "素材の描画準備が再生に追従できません。"
                        self.status.stringValue = "素材の描画準備が再生に追従できません。一時停止しました。"
                        continue
                    }
                    self.displayedPreviewKey = request.key
                    self.preview.visuals = layers
                    self.preview.renderedTime = request.time
                    self.preview.frameFailure = false; self.preview.frameStatus = nil
                    self.preview.invalidateFrame()
                } catch is CancellationError { return }
                catch {
                    guard request.revision == self.previewRevision else { continue }
                    self.stopPlayback(); self.preview.visuals = []
                    self.preview.frameFailure = true; self.preview.frameStatus = "素材を確認してください。素材管理から置き換えられます。"
                    self.status.stringValue = "素材を確認してください: " + error.localizedDescription
                    self.preview.invalidateFrame()
                    self.pendingFrame = nil
                }
            }
        }
    }
    private func prepareTransients() {
        transientPreparation?.cancel()
        let revision = UUID(); transientRevision = revision
        guard let features = preview.features, let url = audioURL else { return }
        placementEditor.timeline.audioFeatures = features
        placementEditor.visuals.musicEditor.features = features
        placementEditor.visuals.musicEditor.analysisError = nil
        let bands = visualTrack.requiredTransientBands
        guard bands.contains(where: { features.transientEvents[$0] == nil }) else { return }
        transientPreparation = Task { [weak self] in
            do {
                let prepared = try await TransientAnalysisService.shared.prepare(features, url: url, bands: bands)
                guard let self, !Task.isCancelled, self.transientRevision == revision, self.audioURL == url else { return }
                self.preview.features = prepared
                self.placementEditor.timeline.audioFeatures = prepared
                self.placementEditor.visuals.musicEditor.features = prepared
                self.preview.invalidateFrame()
            } catch is CancellationError { }
            catch {
                guard let self, self.transientRevision == revision else { return }
                self.placementEditor.visuals.musicEditor.analysisError = "解析失敗: " + error.localizedDescription
                self.status.stringValue = "帯域解析失敗: " + error.localizedDescription
            }
        }
    }

    @objc private func exportVideo() {
        guard placementEditor.finishEditing() else { status.stringValue = "入力を確定してください。"; return }; updateSettings()
        guard let features = preview.features, let audioURL, let projectURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "Music Video.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        stopPlayback(); setBusy(true); progress.doubleValue = 0; status.stringValue = "動画を書き出しています…"
        let token = ExportCancellation(); cancellation = token
        let settings = preview.settings
        let lyrics = preview.lyrics
        let visuals = visualTrack
        let progressIndicator = progress
        exportTask = Task {
            do {
                try await VideoExporter.export(visuals: visuals, projectURL: projectURL, audioURL: audioURL, features: features, settings: settings, lyrics: lyrics, destination: destination, cancellation: token) { value in
                    Task { @MainActor in progressIndicator.doubleValue = value }
                }
                status.stringValue = "書き出し完了: " + destination.lastPathComponent
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError { status.stringValue = "書き出しをキャンセルしました。" }
            catch {
                placementEditor.restoreTab(.visuals)
                let alert = NSAlert(error: error)
                alert.addButton(withTitle: "閉じる"); alert.addButton(withTitle: "素材管理…")
                alert.beginSheetModal(for: window) { [weak self = self] response in
                    if response == .alertSecondButtonReturn { self?.placementEditor.visuals.openManager() }
                }
            }
            cancellation = nil; setBusy(false)
        }
    }
    @objc private func cancelWork() { analysisTask?.cancel(); cancellation?.cancel() }
    private func setBusy(_ value: Bool) { busy = value; cancel.isHidden = !value; refreshControls() }
    private func refreshControls() {
        let enabled = !busy && !imageProcessing
        if !enabled { (window as? StudioWindow)?.cancelNumberDrags() }
        preview.handles.canEdit = enabled
        placementEditor.setAvailable(hasAudio: player != nil, isBusy: !enabled)
        for control in controls { control.isEnabled = enabled }
        play.isEnabled = enabled && player != nil; seek.isEnabled = enabled && player != nil
        manageAssets.isEnabled = enabled && player != nil
        export.isEnabled = enabled && preview.features != nil
    }
    private func showError(_ error: Error) { status.stringValue = "エラー: " + error.localizedDescription; let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    private func prepareToClose() -> Bool {
        preview.handles.cancelDrag()
        guard !busy && !imageProcessing else {
            NSSound.beep(); status.stringValue = "処理をキャンセルしてから終了してください。"
            return false
        }
        (window as? StudioWindow)?.cancelNumberDrags()
        placementEditor.cancelTimelineEdit()
        guard placementEditor.finishEditing() else { return false }
        guard window.makeFirstResponder(nil) else { return false }
        readSceneSettings()
        guard saveProject() else { NSSound.beep(); return false }
        return true
    }
    func windowDidResignKey(_ notification: Notification) { preview.handles.cancelDrag() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToClose() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareToClose() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        transientPreparation?.cancel()
        playbackPreparation?.cancel(); previewFrameTask?.cancel(); pendingFrame = nil
        Task { await previewFrames.invalidate() }
        timer?.invalidate(); timer = nil
        player?.stop()
    }
}
