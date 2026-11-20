import Foundation

extension ImageEffects {
    struct FireOutline: Codable, Equatable, Sendable {
        var isEnabled = true
        var x = 960.0
        var y = 540.0
        var width = 1920.0
        var height = 1080.0
        var spread = 100.0
        var detail = 100.0
        var speed = 100.0
        var brightness = 100.0
        var opacity = 100.0
        var hue = 0.0
        var phaseOffset = 0.0

        struct Field {
            let parameter: ImageParameter
            let title: String
            let unit: String
            let path: WritableKeyPath<FireOutline, Double>
            let range: ClosedRange<Double>
        }
        static let fields: [Field] = [
            Field(parameter: .fireX, title: "中心X", unit: "px", path: \.x, range: -1920...3840),
            Field(parameter: .fireY, title: "中心Y", unit: "px", path: \.y, range: -1080...2160),
            Field(parameter: .fireWidth, title: "幅", unit: "px", path: \.width, range: 1...7680),
            Field(parameter: .fireHeight, title: "高さ", unit: "px", path: \.height, range: 1...4320),
            Field(parameter: .fireSpread, title: "炎の広がり", unit: "%", path: \.spread, range: 0...400),
            Field(parameter: .fireDetail, title: "模様の細かさ", unit: "%", path: \.detail, range: 25...400),
            Field(parameter: .fireSpeed, title: "速度", unit: "%", path: \.speed, range: 0...400),
            Field(parameter: .fireBrightness, title: "明るさ", unit: "%", path: \.brightness, range: 0...200),
            Field(parameter: .fireOpacity, title: "不透明度", unit: "%", path: \.opacity, range: 0...100),
            Field(parameter: .fireHue, title: "色相", unit: "°", path: \.hue, range: -180...180)
        ]
        static let parameters = fields.map(\.parameter)
        static let fieldsByParameter = Dictionary(uniqueKeysWithValues: fields.map { ($0.parameter, $0) })
        var isValid: Bool {
            Self.fields.allSatisfy { self[keyPath: $0.path].isFinite && $0.range.contains(self[keyPath: $0.path]) }
                && phaseOffset.isFinite && abs(phaseOffset) < 1e12
        }
        var isVisible: Bool {
            isEnabled && spread > 0 && brightness > 0 && opacity > 0
                && x + width / 2 > 0 && x - width / 2 < 1920
                && y + height / 2 > 0 && y - height / 2 < 1080
        }
        func clock(at localTime: Double) -> Double { (localTime + phaseOffset) * speed / 100 }

        struct Uniforms {
            var rectangle: SIMD4<Float>
            var pattern: SIMD4<Float>
            var output: SIMD4<Float>
        }
        func uniforms(at localTime: Double, scale: Double, opacity clipOpacity: Float) -> Uniforms {
            Uniforms(rectangle: SIMD4(Float(x), Float(y), Float(width), Float(height)),
                     pattern: SIMD4(Float(spread / 100), Float(detail / 100),
                                    Float(clock(at: localTime).truncatingRemainder(dividingBy: 100000)), Float(hue / 360)),
                     output: SIMD4(Float(brightness * opacity / 10000) * clipOpacity, Float(scale), 0, 0))
        }
    }
}
