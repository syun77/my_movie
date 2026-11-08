import AppKit
import CoreText

struct LyricsColor: Codable, Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = LyricsColor(red: 0, green: 0, blue: 0)
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

struct LyricClip: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct LyricsTrack: Codable, Sendable, Equatable {
    var clips: [LyricClip] = []
    var outlineWidth = 3.0
    var outlineColor = LyricsColor.black

    func text(at time: Double) -> String? {
        clips.first { $0.start <= time && time < $0.end }?.text
    }

    func validate(duration: Double? = nil) throws {
        guard outlineWidth.isFinite, (0...12).contains(outlineWidth), outlineColor.isValid else {
            throw StudioError.message("縁取りの設定が不正です。")
        }
        var previousEnd = 0.0
        var ids = Set<UUID>()
        for clip in clips {
            guard clip.start.isFinite, clip.end.isFinite, clip.start >= previousEnd,
                  clip.end - clip.start >= 1.0 / 30 - 1e-9,
                  duration.map({ clip.end <= $0 + 1e-9 }) ?? true,
                  ids.insert(clip.id).inserted else {
                throw StudioError.message("歌詞の区間は曲の範囲内で、重ならないように設定してください（最小1フレーム）。")
            }
            previousEnd = clip.end
        }
    }
}

enum LyricsRenderer {
    static func draw(in context: CGContext, size: CGSize, track: LyricsTrack, time: Double) {
        guard let text = track.text(at: time) else { return }
        let fontSize = size.height * 0.05
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let box = CGRect(x: size.width * 0.08, y: size.height * 0.30, width: size.width * 0.84, height: size.height * 0.20)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.setLineJoin(.round)
        func drawFrame(_ values: [NSAttributedString.Key: Any]) {
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            let string = NSAttributedString(string: text, attributes: values)
            let setter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
            CTFrameDraw(frame, context)
        }
        if track.outlineWidth > 0 {
            let width = track.outlineWidth * size.height / 720
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = track.outlineColor.cgColor
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = 200 * width / fontSize
            drawFrame(attributes)
            attributes.removeValue(forKey: NSAttributedString.Key(kCTStrokeColorAttributeName as String))
            attributes.removeValue(forKey: NSAttributedString.Key(kCTStrokeWidthAttributeName as String))
        }
        drawFrame(attributes)
    }
}
