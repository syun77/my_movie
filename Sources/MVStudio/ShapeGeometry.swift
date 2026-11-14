import Foundation

struct ShapeGeometry: Codable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case rectangle, triangle, ellipse, star
        var title: String {
            switch self {
            case .rectangle: return "長方形"
            case .triangle: return "三角形"
            case .ellipse: return "楕円"
            case .star: return "星"
            }
        }
    }
    var kind: Kind = .rectangle
    var width = 400.0
    var height = 400.0
    var x = 960.0
    var y = 540.0
    var rotation = 0.0
    var points = 5.0
    var innerRatio = 45.0

    static let sizeRange = 0.0...7680
    static let positionRange = -7680.0...7680
    static let rotationRange = -180.0...180
    static let pointsRange = 3.0...12
    static let innerRatioRange = 5.0...95
    var isValid: Bool {
        Self.sizeRange.contains(width) && Self.sizeRange.contains(height)
            && Self.positionRange.contains(x) && Self.positionRange.contains(y)
            && Self.rotationRange.contains(rotation) && Self.pointsRange.contains(points)
            && points == points.rounded() && Self.innerRatioRange.contains(innerRatio)
    }
}

extension ImageEffects {
    struct Shape: Codable, Equatable, Sendable {
        var isEnabled = true
        var geometry = ShapeGeometry()
        var color = RGBColor.white
        var opacity = 100.0
        var isValid: Bool { geometry.isValid && color.isValid && (0...100).contains(opacity) }
    }
    struct Mask: Codable, Equatable, Sendable {
        enum Target: String, CaseIterable, Codable, Sendable {
            case image, below
            var title: String { self == .image ? "このクリップの画像" : "直下のレイヤーのクリップ" }
        }
        var isEnabled = true
        var geometry = ShapeGeometry()
        var target: Target = .image
        var inverted = false
        var feather = 0.0
        var strength = 100.0
        var isValid: Bool { geometry.isValid && (0...200).contains(feather) && (0...100).contains(strength) }
    }
}
