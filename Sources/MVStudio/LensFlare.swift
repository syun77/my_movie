import Foundation

extension ImageEffects {
    struct LensFlare: Codable, Equatable, Sendable {
        var isEnabled = true
        var automaticMotion = false
        var phaseOffset = 0.0
        var x = 1440.0
        var y = 270.0
        var size = 100.0
        var intensity = 100.0
        func sourcePosition(at time: Double) -> SIMD2<Double> {
            guard automaticMotion else { return SIMD2(x / 1920, y / 1080) }
            let t = time + phaseOffset
            return SIMD2(0.5 + sin(t) * 0.5 * 1080 / 1920, 0.5 - sin(t * 0.913) * 0.5)
        }
        static let parameters: [ImageParameter] = [.flareX, .flareY, .flareSize, .flareIntensity]
        var isValid: Bool {
            let effects = ImageEffects(lensFlare: self)
            return phaseOffset.isFinite && abs(phaseOffset) < 1e12 && Self.parameters.allSatisfy { parameter in
                guard let value = parameter.effect?.read(effects) else { return false }
                return parameter.accepts(value)
            }
        }
    }
}


extension ImageEffects.LensFlare {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, automaticMotion, phaseOffset, x, y, size, intensity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        automaticMotion = try values.decodeIfPresent(Bool.self, forKey: .automaticMotion) ?? false
        phaseOffset = try values.decodeIfPresent(Double.self, forKey: .phaseOffset) ?? 0
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        size = try values.decode(Double.self, forKey: .size)
        intensity = try values.decode(Double.self, forKey: .intensity)
    }
}
