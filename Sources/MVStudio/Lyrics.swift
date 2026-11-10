import AppKit
import CoreText

struct LyricClip: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var predecessorID: UUID? = nil
}

struct LyricsTypography: Codable, Sendable, Equatable {
    static let defaultFontName = "HiraginoSans-W6"

    var fontName = Self.defaultFontName
    var fontSize = 54
    var x = VideoExporter.width / 2
    var y = VideoExporter.height / 2

    enum Field: CaseIterable {
        case fontSize, x, y

        var keyPath: WritableKeyPath<LyricsTypography, Int> {
            switch self {
            case .fontSize: \.fontSize
            case .x: \.x
            case .y: \.y
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .fontSize: 8...216
            case .x: 0...VideoExporter.width
            case .y: 0...VideoExporter.height
            }
        }
    }

    var isValid: Bool {
        !fontName.isEmpty && Field.allCases.allSatisfy { $0.range.contains(self[keyPath: $0.keyPath]) }
    }

    func updating(_ field: Field, to value: Int) -> Self {
        var result = self
        result[keyPath: field.keyPath] = min(field.range.upperBound, max(field.range.lowerBound, value))
        return result
    }
}

struct LyricsStyle: PresetSettings, Equatable {
    static let presetFilename = "Lyrics.json"

    var outlineWidth: Double
    var outlineColor: RGBColor
    var typography: LyricsTypography

    func validate() throws {
        guard outlineWidth.isFinite, (0...12).contains(outlineWidth), outlineColor.isValid else {
            throw StudioError.message("縁取りの設定が不正です。")
        }
        guard typography.isValid else {
            throw StudioError.message("歌詞のフォントまたは描画位置の設定が不正です。")
        }
    }
}

struct LyricsTrack: Codable, Sendable, Equatable {
    var clips: [LyricClip] = []
    var outlineWidth = 3.0
    var outlineColor = RGBColor.black
    var typography = LyricsTypography()

    var style: LyricsStyle {
        get { LyricsStyle(outlineWidth: outlineWidth, outlineColor: outlineColor, typography: typography) }
        set {
            outlineWidth = newValue.outlineWidth
            outlineColor = newValue.outlineColor
            typography = newValue.typography
        }
    }

    func text(at time: Double) -> String? {
        clips.first { $0.start <= time && time < $0.end }?.text
    }

    func validate(duration: Double? = nil) throws {
        try style.validate()
        var previousEnd = 0.0
        var previousID: UUID?
        var ids = Set<UUID>()
        for clip in clips {
            guard clip.start.isFinite, clip.end.isFinite, clip.start >= previousEnd,
                  clip.end - clip.start >= 1.0 / 30 - 1e-9,
                  duration.map({ clip.end <= $0 + 1e-9 }) ?? true,
                  ids.insert(clip.id).inserted,
                  clip.predecessorID == nil || (clip.predecessorID == previousID && abs(clip.start - previousEnd) < 1e-9) else {
                throw StudioError.message("歌詞の区間は曲の範囲内で、重ならないように設定してください（最小1フレーム）。")
            }
            previousEnd = clip.end
            previousID = clip.id
        }
    }
}

extension LyricsTrack {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clips = try values.decode([LyricClip].self, forKey: .clips)
        outlineWidth = try values.decode(Double.self, forKey: .outlineWidth)
        outlineColor = try values.decode(RGBColor.self, forKey: .outlineColor)
        typography = try values.decodeIfPresent(LyricsTypography.self, forKey: .typography) ?? LyricsTypography()
    }
}

enum LyricsRenderer {
    static func draw(in context: CGContext, size: CGSize, track: LyricsTrack, time: Double) {
        guard let text = track.text(at: time) else { return }
        let style = track.typography
        let scaleX = size.width / CGFloat(VideoExporter.width)
        let scaleY = size.height / CGFloat(VideoExporter.height)
        let top = size.height - CGFloat(style.y) * scaleY
        guard top > 0 else { return }
        let fontSize = CGFloat(style.fontSize) * scaleY
        let requestedFont = CTFontCreateWithName(style.fontName as CFString, fontSize, nil)
        let font = CTFontCopyPostScriptName(requestedFont) as String == style.fontName
            ? requestedFont
            : CTFontCreateWithName(LyricsTypography.defaultFontName as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let width = size.width * 0.84
        let box = CGRect(x: CGFloat(style.x) * scaleX - width / 2, y: 0, width: width, height: top)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
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
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = track.outlineColor.cgColor()
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = 200 * width / fontSize
            drawFrame(attributes)
            attributes.removeValue(forKey: NSAttributedString.Key(kCTStrokeColorAttributeName as String))
            attributes.removeValue(forKey: NSAttributedString.Key(kCTStrokeWidthAttributeName as String))
        }
        drawFrame(attributes)
    }
}
