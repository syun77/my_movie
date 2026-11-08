import AppKit

struct SceneSettings: Codable, Sendable, Equatable {
    var bpm = 120.0
    var beatOffset = 0.0
    var spectrum = true
}

struct AudioFeatures: Sendable {
    let duration: Double
    let step: Double
    let frames: [[Float]]

    func bands(at time: Double) -> [Float] {
        guard !frames.isEmpty, time >= 0, time < duration else { return Array(repeating: 0, count: 32) }
        let position = time / step
        let index = min(Int(position), frames.count - 1)
        let next = min(index + 1, frames.count - 1)
        let fraction = Float(position - Double(index))
        return zip(frames[index], frames[next]).map { $0 + ($1 - $0) * fraction }
    }
}

enum SceneRenderer {
    static func draw(in context: CGContext, size: CGSize, images: [ImageRenderLayer] = [], features: AudioFeatures?, settings: SceneSettings, time: Double, lyrics: LyricsTrack = LyricsTrack()) {
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1))
        context.fill(rect)
        for layer in images where layer.clip.start <= time && time < layer.clip.end {
            let image = layer.image
            let fit = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            let scale = fit * layer.clip.scale(at: time, settings: settings)
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
            context.restoreGState()
        }
        if settings.spectrum, let features {
            let bands = features.bands(at: time)
            let margin = size.width * 0.075
            let stride = (size.width - margin * 2) / CGFloat(bands.count)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.28))
            for (index, value) in bands.enumerated() {
                let height = max(2, CGFloat(value) * size.height * 0.2)
                context.setFillColor(CGColor(red: 0.2, green: 0.85, blue: 0.95, alpha: 0.9))
                context.fill(CGRect(x: margin + CGFloat(index) * stride, y: size.height * 0.04, width: stride * 0.72, height: height))
            }
        }
        LyricsRenderer.draw(in: context, size: size, track: lyrics, time: time)
    }
}
