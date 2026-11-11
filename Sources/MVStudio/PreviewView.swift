import AppKit
import MetalKit

@MainActor
final class PreviewView: NSView, MTKViewDelegate {
    var visuals: [VisualRenderLayer] = []
    var features: AudioFeatures?
    var settings = SceneSettings()
    var spectrumLayoutPreview: SpectrumLayout?
    var lyrics = LyricsTrack()
    var time = 0.0
    var renderedTime = 0.0
    var frameFailure = false
    var frameStatus: String? {
        didSet {
            errorLabel.stringValue = frameStatus ?? ""
            errorLabel.isHidden = frameStatus == nil
        }
    }

    private let surface = MTKView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var renderer: MetalSceneRenderer?
    private var inFlight = false
    private var dirty = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        errorLabel.textColor = .white
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        do {
            let renderer = try MetalSceneRenderer(scale: 0.5)
            self.renderer = renderer
            surface.device = renderer.device
            surface.colorPixelFormat = .bgra8Unorm
            surface.colorspace = MetalSceneRenderer.sRGB
            surface.isPaused = true
            surface.enableSetNeedsDisplay = true
            surface.delegate = self
        } catch {
            showError(error)
        }
        for child in [surface, errorLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func invalidateFrame() {
        dirty = true
        if !inFlight { surface.needsDisplay = true }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidateFrame() }

    func draw(in view: MTKView) {
        guard !inFlight, let renderer, let drawable = view.currentDrawable else { return }
        dirty = false
        var displaySettings = settings
        if let spectrumLayoutPreview { displaySettings.spectrumStyle.layout = spectrumLayoutPreview }
        do {
            let commands = try renderer.encode(visuals: visuals, features: features, settings: displaySettings, lyrics: lyrics,
                                               time: renderedTime, target: drawable.texture, video: false)
            inFlight = true
            commands.addCompletedHandler { [weak self] buffer in
                let failed = buffer.status != .completed
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.inFlight = false
                    if failed {
                        self.renderer?.discardCache()
                        self.showError(MetalSceneRenderer.renderError)
                    } else if self.frameStatus == nil { self.errorLabel.isHidden = true }
                    if self.dirty { self.surface.needsDisplay = true }
                }
            }
            commands.present(drawable)
            commands.commit()
        } catch {
            renderer.discardCache()
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        errorLabel.stringValue = "プレビューを描画できません。\n" + error.localizedDescription
        errorLabel.isHidden = false
    }
}
