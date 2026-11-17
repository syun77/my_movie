import Foundation

extension ImageEffects {
    struct RadialFocus: Codable, Equatable, Sendable {
        var isEnabled = true
        var speed = 100.0
        var zoom = 100.0
        var brightness = 100.0
        var opacity = 100.0
        var phaseOffset = 0.0

        static let parameters: [ImageParameter] = [.radialSpeed, .radialZoom, .radialBrightness, .radialOpacity]
        var isValid: Bool {
            let effects = ImageEffects(radialFocus: self)
            return Self.parameters.allSatisfy { parameter in
                guard let value = parameter.effect?.read(effects) else { return false }
                return parameter.accepts(value)
            } && phaseOffset.isFinite && abs(phaseOffset) < 1e12
        }
    }
}
