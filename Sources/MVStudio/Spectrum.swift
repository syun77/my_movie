import CoreGraphics

struct SpectrumSettings: PresetSettings {
    static let presetFilename = "Spectrum.json"

    var shown: Bool
    var style: SpectrumStyle

    func validate() throws {
        guard style.isValid else { throw StudioError.message("スペクトラムの設定値が不正です。") }
    }
}

struct SpectrumStyle: Codable, Sendable, Equatable {
    enum Shape: String, Codable, Sendable, CaseIterable {
        case bars, line

        var title: String {
            switch self {
            case .bars: "バー"
            case .line: "折れ線"
            }
        }
    }

    enum Resolution: Int, Codable, Sendable, CaseIterable {
        case minimal = 4
        case low = 8
        case medium = 16
        case standard = 32
        case high = 64
    }

    var shape: Shape
    var color: RGBColor
    var resolution: Resolution
    var layout: SpectrumLayout

    var isValid: Bool { color.isValid && layout.isValid }

    init(shape: Shape = .bars, color: RGBColor = RGBColor(red: 0.2, green: 0.85, blue: 0.95),
         resolution: Resolution = .standard, layout: SpectrumLayout = SpectrumLayout()) {
        self.shape = shape
        self.color = color
        self.resolution = resolution
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decode(Shape.self, forKey: .shape)
        color = try container.decode(RGBColor.self, forKey: .color)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        layout = try container.decodeIfPresent(SpectrumLayout.self, forKey: .layout) ?? SpectrumLayout()
    }
}

struct SpectrumLayout: Codable, Sendable, Equatable {
    var x = 144
    var y = 821
    var width = 1632
    var height = 216
    var barGap = 28

    enum Field: CaseIterable {
        case x, y, width, height, barGap

        var keyPath: WritableKeyPath<SpectrumLayout, Int> {
            switch self {
            case .x: \.x
            case .y: \.y
            case .width: \.width
            case .height: \.height
            case .barGap: \.barGap
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .x: -VideoExporter.width...VideoExporter.width
            case .y: -VideoExporter.height...VideoExporter.height
            case .width: 1...VideoExporter.width
            case .height: 1...VideoExporter.height
            case .barGap: 0...90
            }
        }
    }

    var isValid: Bool {
        Field.allCases.allSatisfy { $0.range.contains(self[keyPath: $0.keyPath]) }
    }

    func bounds(in size: CGSize) -> CGRect {
        let scaleX = size.width / CGFloat(VideoExporter.width)
        let scaleY = size.height / CGFloat(VideoExporter.height)
        return CGRect(x: CGFloat(x) * scaleX, y: size.height - CGFloat(y + height) * scaleY,
                      width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY)
    }
}

enum SpectrumRenderer {
    static func draw(in context: CGContext, size: CGSize, features: AudioFeatures, time: Double, style: SpectrumStyle) {
        guard size.width > 0, size.height > 0 else { return }
        let count = style.resolution.rawValue
        let bounds = style.layout.bounds(in: size)
        let color = style.color.cgColor(alpha: 0.9)

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        switch style.shape {
        case .bars:
            let edges = features.bandEdges(at: time, count: count)
            let gapRatio = CGFloat(style.layout.barGap) / 100
            let pitch = bounds.width / (CGFloat(count) - gapRatio)
            let minimumHeight = min(bounds.height, 2 * size.height / CGFloat(VideoExporter.height))
            let path = CGMutablePath()
            for index in 0..<count {
                let left = bounds.minX + CGFloat(index) * pitch
                let right = bounds.minX + (CGFloat(index + 1) - gapRatio) * pitch
                let leftHeight = max(minimumHeight, CGFloat(edges[index]) * bounds.height)
                let rightHeight = max(minimumHeight, CGFloat(edges[index + 1]) * bounds.height)
                path.move(to: CGPoint(x: left, y: bounds.minY))
                path.addLine(to: CGPoint(x: right, y: bounds.minY))
                path.addLine(to: CGPoint(x: right, y: bounds.minY + rightHeight))
                path.addLine(to: CGPoint(x: left, y: bounds.minY + leftHeight))
                path.closeSubpath()
            }
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        case .line:
            let bands = features.bands(at: time, count: count)
            let path = CGMutablePath()
            let pitch = bounds.width / CGFloat(bands.count - 1)
            for (index, value) in bands.enumerated() {
                let point = CGPoint(x: bounds.minX + CGFloat(index) * pitch,
                                    y: bounds.minY + CGFloat(value) * bounds.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.setStrokeColor(color)
            context.setLineWidth(max(1, size.height * 0.004))
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.addPath(path)
            context.strokePath()
        }
    }
}
