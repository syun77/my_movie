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
    private var mouseHistoryGroup: UUID?
    private let preview = PreviewView()
    private let status = NSTextField(labelWithString: "画像と音声を読み込んでください")
    private let audioName = NSTextField(labelWithString: "音声: 未選択")
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let bpm = DragValueField(frame: .zero)
    private let offset = DragValueField(frame: .zero)
    private let play = NSButton(title: "再生", target: nil, action: nil)
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
    private let imageStore = ImageAssetStore()
    private var previewImageTask: Task<Void, Never>?
    private var previewRevision = 0
    private var imageTrack = ImageTrack()
    private var previewTrack = ImageTrack()

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
        studioWindow.onBeginInteraction = { [weak self] in self?.endHistoryGroup(); self?.mouseHistoryGroup = UUID() }
        studioWindow.onEndInteraction = { [weak self] in self?.mouseHistoryGroup = nil; self?.endHistoryGroup() }
        studioWindow.onEscapeInteraction = { [weak self] in self?.placementEditor.images.cancelValueDrag() ?? false }
        studioWindow.onEscapeText = { [weak self] text in self?.placementEditor.images.cancelAnimationInput(text) ?? false }
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
        let files = row([audioButton, audioName])
        audioName.lineBreakMode = .byTruncatingMiddle
        audioName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bpm.widthAnchor.constraint(equalToConstant: 64).isActive = true
        offset.widthAnchor.constraint(equalToConstant: 64).isActive = true
        bpm.identifier = NSUserInterfaceItemIdentifier("scene.bpm"); offset.identifier = NSUserInterfaceItemIdentifier("scene.offset")
        bpm.delegate = self; offset.delegate = self
        bpm.stringValue = "120"; offset.stringValue = "0"
        bpm.bindNumber(current: { [weak self] in self?.preview.settings.bpm }, initial: { SceneSettings().bpm },
                       normalize: { min(300, max(20, $0)) }, commit: { [weak self] _ in self?.updateSettings() })
        offset.bindNumber(step: 0.01, current: { [weak self] in self?.preview.settings.beatOffset },
                          initial: { SceneSettings().beatOffset }, normalize: { max(0, $0) },
                          commit: { [weak self] _ in self?.updateSettings() })
        for control in [bpm, offset] { control.target = self; control.action = #selector(updateSettings) }
        let options = row([NSTextField(labelWithString: "BPM"), bpm, NSTextField(labelWithString: "拍開始（秒）"), offset])
        play.target = self; play.action = #selector(togglePlay)
        export.target = self; export.action = #selector(exportVideo)
        cancel.target = self; cancel.action = #selector(cancelWork)
        cancel.isHidden = true
        seek.target = self; seek.action = #selector(scrubWholeSong)
        seek.isContinuous = true
        seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transport = row([play, seek, timeLabel])
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let output = row([export, NSTextField(labelWithString: "\(VideoExporter.width) × \(VideoExporter.height) · \(VideoExporter.fps)fps · H.264 / AAC"), progress, cancel])
        let timeline = placementEditor.view
        placementEditor.visibleSpan = timelineDisplaySettings.visibleSpan
        placementEditor.snapGrid.division = timelineDisplaySettings.snapDivision
        placementEditor.onSnapDivisionChange = { [weak self] value in self?.timelineDisplaySettings.snapDivision = value }
        placementEditor.showsWholeSong = timelineDisplaySettings.showsWholeSong
        placementEditor.onWholeSongChange = { [weak self] value in self?.timelineDisplaySettings.showsWholeSong = value }
        placementEditor.restoreTab(timelineDisplaySettings.imageMode ? .images : .lyrics)
        placementEditor.onModeChange = { [weak self] value in self?.timelineDisplaySettings.imageMode = value }
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
        placementEditor.images.onBeginTextEditing = { [weak self] in self?.endHistoryGroup() }
        placementEditor.images.onEndTextEditing = { [weak self] in self?.finishTextHistoryGroup() }
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
        placementEditor.images.onProcessing = { [weak self] value in self?.imageProcessing = value; self?.refreshControls() }
        placementEditor.images.onAssetsReload = { [weak self] in
            guard let self else { return }
            self.lastPreviewKey = nil; self.refreshPreviewImages()
        }
        placementEditor.images.onBeginEdit = { [weak self] in _ = self?.lyricsEditor.onCapturePlaybackTime?() }
        placementEditor.images.onSeek = { [weak self] time in self?.lyricsEditor.onSeek?(time) }
        placementEditor.images.onChange = { [weak self] value in
            guard let self else { return }
            self.recordEdit(images: value); self.stopPlayback(); self.imageTrack = value; self.previewTrack = value; self.refreshPreviewImages(); _ = self.saveProject()
        }
        placementEditor.images.onPreview = { [weak self] value in self?.previewTrack = value; self?.refreshPreviewImages() }
        installLayout(toolbar: row([files, output]), options: options, transport: transport, timeline: timeline)
        controls = [audioButton, bpm, offset, play, seek, export]
        refreshControls()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        editHistory.reset(EditSnapshot(lyrics: preview.lyrics, images: imageTrack, settings: preview.settings))
        if let url = storage.lastProjectURL { openProject(at: url) }
    }

    private func installLayout(toolbar: NSView, options: NSView, transport: NSView, timeline: NSView) {
        let content = NSView()
        window.contentView = content

        let workspace = NSView()
        let inspector = placementEditor.inspector
        for child in [preview, options, inspector] {
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
        let root = NSStackView(views: [toolbar, workspace, divider, transport, timeline, status])
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
            preview.bottomAnchor.constraint(equalTo: options.topAnchor, constant: -8),
            options.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            options.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
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
    private func openProject(at url: URL) {
        do {
            let project = try storage.read(from: url)
            loadAudio(at: project.audio.resolve(projectURL: url), projectURL: url, restoring: project)
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
    private func loadAudio(at url: URL, projectURL: URL, restoring project: ProjectFile?) {
        stopPlayback(); setBusy(true); status.stringValue = "音声を解析しています…"; progress.isIndeterminate = true; progress.startAnimation(nil)
        analysisTask = Task {
            do {
                let task = Task.detached { try AudioAnalyzer.analyze(url: url) }
                let features = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                let loaded = try AVAudioPlayer(contentsOf: url); loaded.prepareToPlay()
                try project?.lyrics.validate(duration: features.duration)
                try project?.images.validate(duration: features.duration)
                player = loaded; audioURL = url; preview.features = features; preview.time = 0
                self.projectURL = projectURL
                lyricsEditor.clearPresetSelection()
                placementEditor.spectrum.clearPresetSelection()
                if let project { restoreSceneSettings(project.settings) }
                placementEditor.restoreTimelineHeights(project?.timelineHeights ?? TimelineHeights())
                preview.lyrics = project?.lyrics ?? LyricsTrack()
                imageTrack = project?.images ?? ImageTrack(); previewTrack = imageTrack
                placementEditor.images.load(imageTrack, projectURL: projectURL)
                lyricsEditor.load(preview.lyrics); placementEditor.duration = features.duration
                seek.maxValue = features.duration; seek.doubleValue = 0; updateTime()
                audioName.stringValue = "音声: " + url.lastPathComponent
                lastPreviewKey = nil; preview.images = []
                editHistory.reset(EditSnapshot(lyrics: preview.lyrics, images: imageTrack, settings: preview.settings)); endHistoryGroup()
                _ = saveProject(); refreshPreviewImages()
            } catch is CancellationError { status.stringValue = "解析をキャンセルしました。" }
            catch { showError(error) }
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 0; setBusy(false); preview.invalidateFrame()
        }
    }
    @discardableResult private func saveProject() -> Bool {
        guard let audioURL, let projectURL else { return true }
        do {
            try storage.save(ProjectFile(audioURL: audioURL, images: imageTrack, settings: preview.settings, lyrics: preview.lyrics,
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
    }

    private func endHistoryGroup() {
        textHistoryResponder = nil; textHistoryGroup = nil
    }
    private func finishTextHistoryGroup() {
        endHistoryGroup()
        if mouseHistoryGroup != nil { mouseHistoryGroup = UUID() }
    }
    private func recordEdit(lyrics: LyricsTrack? = nil, images: ImageTrack? = nil, settings: SceneSettings? = nil) {
        if let text = window?.firstResponder as? NSTextView, text.isEditable {
            let identity = ObjectIdentifier(text)
            if textHistoryResponder != identity { textHistoryGroup = UUID(); textHistoryResponder = identity }
        } else { endHistoryGroup() }
        var value = editHistory.current
        if let lyrics { value.lyrics = lyrics }
        if let images { value.images = images }
        if let settings { value.settings = settings }
        editHistory.record(value, group: mouseHistoryGroup ?? textHistoryGroup)
    }
    private var historyIsAvailable: Bool {
        guard let window, !busy, !imageProcessing, NSApp.modalWindow == nil else { return false }
        if let sheet = window.attachedSheet { return sheet === placementEditor.images.managerWindow }
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
        guard historyIsAvailable else { return }
        if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { NSSound.beep(); return }
        (window as? StudioWindow)?.cancelNumberDrags()
        placementEditor.cancelTimelineEdit()
        guard window.makeFirstResponder(nil) else { return }
        endHistoryGroup()
        guard let value = redo ? editHistory.redo() : editHistory.undo() else { return }
        stopPlayback()
        restoreSceneSettings(value.settings); preview.lyrics = value.lyrics
        imageTrack = value.images; previewTrack = value.images
        lyricsEditor.restore(value.lyrics); placementEditor.images.restore(value.images)
        lastPreviewKey = nil; refreshPreviewImages(); preview.invalidateFrame()
        _ = saveProject()
    }
    @objc private func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            placementEditor.timeline.followPlayhead()
            if player.currentTime >= player.duration - 0.01 { player.currentTime = 0 }
            player.play()
        }
        tick()
    }
    private func stopPlayback() { player?.pause(); play.title = "再生" }
    @objc private func scrubWholeSong() {
        placementEditor.timeline.followPlayhead()
        scrub()
    }
    private func scrub() { player?.currentTime = seek.doubleValue; preview.time = seek.doubleValue; preview.invalidateFrame(); updateTime() }
    private func tick() {
        guard let player, !busy else { return }
        if player.isPlaying { preview.time = player.currentTime; seek.doubleValue = player.currentTime; preview.invalidateFrame() }
        play.title = player.isPlaying ? "一時停止" : "再生"; updateTime()
    }
    private func updateTime() {
        placementEditor.currentTime = preview.time
        refreshPreviewImages()
        func format(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
        timeLabel.stringValue = "\(format(preview.time)) / \(format(preview.features?.duration ?? 0))"
    }
    private struct PreviewKey: Equatable {
        let projectURL: URL
        let clips: [ImageClip]
        let assets: [ImageAsset]
    }
    private var lastPreviewKey: PreviewKey?
    private func refreshPreviewImages() {
        guard let projectURL else { return }
        let track = previewTrack, time = preview.time
        let active = track.active(at: time)
        let key = PreviewKey(projectURL: projectURL, clips: active, assets: active.compactMap { track.asset($0.assetID) })
        guard key != lastPreviewKey else { return }
        let previousKey = lastPreviewKey
        lastPreviewKey = key; previewRevision += 1
        let revision = previewRevision
        previewImageTask?.cancel()
        if previousKey?.projectURL == projectURL, previousKey?.assets == key.assets,
           let previous = previousKey?.clips, preview.images.map(\.clip) == previous,
           previous.map(\.assetID) == active.map(\.assetID) {
            preview.images = zip(active, preview.images).map { ImageRenderLayer(clip: $0, image: $1.image) }
            preview.invalidateFrame()
            return
        }
        previewImageTask = Task { [weak self] in
            guard let self else { return }
            let layers = (try? await imageStore.layers(track: track, projectURL: projectURL, time: time, allowMissing: true)) ?? []
            guard !Task.isCancelled, revision == previewRevision else { return }
            preview.images = layers; preview.invalidateFrame()
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
        let images = imageTrack
        let progressIndicator = progress
        exportTask = Task {
            do {
                try await VideoExporter.export(images: images, projectURL: projectURL, audioURL: audioURL, features: features, settings: settings, lyrics: lyrics, destination: destination, cancellation: token) { value in
                    Task { @MainActor in progressIndicator.doubleValue = value }
                }
                status.stringValue = "書き出し完了: " + destination.lastPathComponent
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError { status.stringValue = "書き出しをキャンセルしました。" }
            catch {
                placementEditor.restoreTab(.images)
                let alert = NSAlert(error: error)
                alert.addButton(withTitle: "閉じる"); alert.addButton(withTitle: "画像管理…")
                alert.beginSheetModal(for: window) { [weak self = self] response in
                    if response == .alertSecondButtonReturn { self?.placementEditor.images.openManager() }
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
        placementEditor.setAvailable(hasAudio: player != nil, isBusy: !enabled)
        for control in controls { control.isEnabled = enabled }
        play.isEnabled = enabled && player != nil; seek.isEnabled = enabled && player != nil
        export.isEnabled = enabled && preview.features != nil
    }
    private func showError(_ error: Error) { status.stringValue = "エラー: " + error.localizedDescription; let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    private func prepareToClose() -> Bool {
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
    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToClose() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareToClose() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        previewImageTask?.cancel()
        timer?.invalidate(); timer = nil
        player?.stop()
    }
}
