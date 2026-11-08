import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

final class PreviewView: NSView {
    var image: CGImage?
    var features: AudioFeatures?
    var settings = SceneSettings()
    var time = 0.0
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)
        let width = min(bounds.width, bounds.height * 16 / 9)
        let size = CGSize(width: width, height: width * 9 / 16)
        context.saveGState()
        context.translateBy(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        SceneRenderer.draw(in: context, size: size, image: image, features: features, settings: settings, time: time)
        context.restoreGState()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let preview = PreviewView()
    private let status = NSTextField(labelWithString: "画像と音声を読み込んでください")
    private let imageName = NSTextField(labelWithString: "画像: 未選択")
    private let audioName = NSTextField(labelWithString: "音声: 未選択")
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let bpm = NSTextField(string: "120")
    private let offset = NSTextField(string: "0")
    private let pulse = NSSlider(value: 8, minValue: 0, maxValue: 25, target: nil, action: nil)
    private let spectrum = NSButton(checkboxWithTitle: "スペクトラムを表示", target: nil, action: nil)
    private let play = NSButton(title: "再生", target: nil, action: nil)
    private let export = NSButton(title: "MP4を書き出す", target: nil, action: nil)
    private let cancel = NSButton(title: "キャンセル", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var player: AVAudioPlayer?
    private var audioURL: URL?
    private var timer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var cancellation: ExportCancellation?
    private var busy = false
    private var controls = [NSControl]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MV Studio"
        window.minSize = NSSize(width: 900, height: 650)
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let title = NSTextField(labelWithString: "MV Studio")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(labelWithString: "画像と音楽から、リズムに反応する映像を。")
        subtitle.textColor = .secondaryLabelColor
        let imageButton = button("画像を選択…", #selector(importImage))
        let audioButton = button("音声を選択…", #selector(importAudio))
        let files = row([imageButton, imageName, audioButton, audioName])
        imageName.lineBreakMode = .byTruncatingMiddle
        audioName.lineBreakMode = .byTruncatingMiddle
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        bpm.widthAnchor.constraint(equalToConstant: 64).isActive = true
        offset.widthAnchor.constraint(equalToConstant: 64).isActive = true
        pulse.widthAnchor.constraint(equalToConstant: 140).isActive = true
        spectrum.state = .on
        for control in [bpm, offset, pulse, spectrum] as [NSControl] { control.target = self; control.action = #selector(updateSettings) }
        let options = row([NSTextField(labelWithString: "BPM"), bpm, NSTextField(labelWithString: "拍開始（秒）"), offset, NSTextField(labelWithString: "拡大の強さ"), pulse, spectrum])
        play.target = self; play.action = #selector(togglePlay)
        export.target = self; export.action = #selector(exportVideo)
        cancel.target = self; cancel.action = #selector(cancelWork)
        cancel.isHidden = true
        seek.target = self; seek.action = #selector(scrub)
        seek.isContinuous = true
        seek.widthAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        let transport = row([play, seek, timeLabel])
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let output = row([export, NSTextField(labelWithString: "1280 × 720 · 30fps · H.264 / AAC"), progress, cancel])
        for view in [title, subtitle, files, preview, options, transport, output, status] { root.addArrangedSubview(view) }
        for view in [files, preview, options, transport, output, status] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true }
        controls = [imageButton, audioButton, bpm, offset, pulse, spectrum, play, seek, export]
        refreshControls()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func row(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.spacing = 12; stack.alignment = .centerY; return stack }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); app.addItem(withTitle: "MV Studioを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = app
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "編集")
        for (title, action, key) in [("カット", "cut:", "x"), ("コピー", "copy:", "c"), ("ペースト", "paste:", "v"), ("すべて選択", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        editItem.submenu = edit; NSApp.mainMenu = menu
    }
    private func choose(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    @objc private func importImage() {
        guard let url = choose([.png, .jpeg, .tiff]), let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        preview.image = image; imageName.stringValue = "画像: " + url.lastPathComponent; preview.needsDisplay = true; refreshControls()
    }
    @objc private func importAudio() {
        guard let url = choose([.audio]) else { return }
        stopPlayback(); setBusy(true); status.stringValue = "音声を解析しています…"; progress.isIndeterminate = true; progress.startAnimation(nil)
        analysisTask = Task {
            do {
                let task = Task.detached { try AudioAnalyzer.analyze(url: url) }
                let features = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                let loaded = try AVAudioPlayer(contentsOf: url); loaded.prepareToPlay()
                player = loaded; audioURL = url; preview.features = features; preview.time = 0
                seek.maxValue = features.duration; seek.doubleValue = 0
                audioName.stringValue = "音声: " + url.lastPathComponent
                status.stringValue = "解析完了。BPMを合わせて再生してください。"
            } catch is CancellationError { status.stringValue = "解析をキャンセルしました。" }
            catch { showError(error) }
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 0; setBusy(false); preview.needsDisplay = true
        }
    }
    @objc private func updateSettings() {
        let bpmValue = Double(bpm.stringValue) ?? 120
        let offsetValue = Double(offset.stringValue) ?? 0
        preview.settings = SceneSettings(bpm: bpmValue.isFinite ? min(300, max(20, bpmValue)) : 120, beatOffset: offsetValue.isFinite ? max(0, offsetValue) : 0, pulse: pulse.doubleValue / 100, spectrum: spectrum.state == .on)
        bpm.stringValue = String(format: "%.1f", preview.settings.bpm)
        offset.stringValue = String(format: "%.2f", preview.settings.beatOffset)
        preview.needsDisplay = true
    }
    @objc private func togglePlay() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { if player.currentTime >= player.duration - 0.01 { player.currentTime = 0 }; player.play() }
        tick()
    }
    private func stopPlayback() { player?.pause(); play.title = "再生" }
    @objc private func scrub() { player?.currentTime = seek.doubleValue; preview.time = seek.doubleValue; preview.needsDisplay = true; updateTime() }
    private func tick() {
        guard let player, !busy else { return }
        if player.isPlaying { preview.time = player.currentTime; seek.doubleValue = player.currentTime; preview.needsDisplay = true }
        play.title = player.isPlaying ? "一時停止" : "再生"; updateTime()
    }
    private func updateTime() {
        func format(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
        timeLabel.stringValue = "\(format(preview.time)) / \(format(preview.features?.duration ?? 0))"
    }
    @objc private func exportVideo() {
        window.makeFirstResponder(nil); updateSettings()
        guard let image = preview.image, let features = preview.features, let audioURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "Music Video.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        stopPlayback(); setBusy(true); progress.doubleValue = 0; status.stringValue = "動画を書き出しています…"
        let token = ExportCancellation(); cancellation = token
        let settings = preview.settings
        let progressIndicator = progress
        exportTask = Task {
            do {
                try await VideoExporter.export(image: image, audioURL: audioURL, features: features, settings: settings, destination: destination, cancellation: token) { value in
                    Task { @MainActor in progressIndicator.doubleValue = value }
                }
                status.stringValue = "書き出し完了: " + destination.lastPathComponent
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError { status.stringValue = "書き出しをキャンセルしました。" }
            catch { showError(error) }
            cancellation = nil; setBusy(false)
        }
    }
    @objc private func cancelWork() { analysisTask?.cancel(); cancellation?.cancel() }
    private func setBusy(_ value: Bool) { busy = value; cancel.isHidden = !value; refreshControls() }
    private func refreshControls() {
        for control in controls { control.isEnabled = !busy }
        play.isEnabled = !busy && player != nil; seek.isEnabled = !busy && player != nil
        export.isEnabled = !busy && preview.image != nil && preview.features != nil
    }
    private func showError(_ error: Error) { status.stringValue = "エラー: " + error.localizedDescription; let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { NSSound.beep(); status.stringValue = "処理をキャンセルしてから終了してください。"; return .terminateCancel }
        return .terminateNow
    }
}
