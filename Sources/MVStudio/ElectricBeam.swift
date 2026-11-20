import Foundation

extension ImageEffects {
    struct ElectricBeam: Codable, Equatable, Sendable {
        var isEnabled = true
        var x = 960.0
        var y = 540.0
        var angle = -30.0
        var length = 2400.0
        var spread = 180.0
        var count = 6.0
        var width = 3.0
        var bend = 90.0
        var glowRadius = 48.0
        var brightness = 100.0
        var speed = 100.0
        var color = RGBColor(red: 0.20, green: 0.75, blue: 1)
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        struct Field {
            let parameter: ImageParameter
            let title: String
            let unit: String
            let path: WritableKeyPath<ElectricBeam, Double>
            let range: ClosedRange<Double>
        }
        static let fields: [Field] = [
            Field(parameter: .beamX, title: "中心X", unit: "px", path: \.x, range: -1920...3840),
            Field(parameter: .beamY, title: "中心Y", unit: "px", path: \.y, range: -1080...2160),
            Field(parameter: .beamAngle, title: "角度", unit: "°", path: \.angle, range: -180...180),
            Field(parameter: .beamLength, title: "長さ", unit: "px", path: \.length, range: 1...7680),
            Field(parameter: .beamSpread, title: "束の幅", unit: "px", path: \.spread, range: 0...1080),
            Field(parameter: .beamCount, title: "本数", unit: "", path: \.count, range: 1...6),
            Field(parameter: .beamWidth, title: "太さ", unit: "px", path: \.width, range: 0.5...40),
            Field(parameter: .beamBend, title: "折れ曲がり", unit: "px", path: \.bend, range: 0...400),
            Field(parameter: .beamGlow, title: "光の広がり", unit: "px", path: \.glowRadius, range: 0...300),
            Field(parameter: .beamBrightness, title: "明るさ", unit: "%", path: \.brightness, range: 0...400),
            Field(parameter: .beamSpeed, title: "動きの速さ", unit: "%", path: \.speed, range: 0...400)
        ]
        static let parameters = fields.map(\.parameter)
        static let fieldsByParameter = Dictionary(uniqueKeysWithValues: fields.map { ($0.parameter, $0) })
        var isValid: Bool {
            Self.fields.allSatisfy { self[keyPath: $0.path].isFinite && $0.range.contains(self[keyPath: $0.path]) }
                && color.isValid && phaseOffset.isFinite && abs(phaseOffset) < 1e12
        }
        func frame(at localTime: Double) -> Int64 {
            Int64(floor((localTime + phaseOffset) * speed / 100 * 24))
        }
    }
}
