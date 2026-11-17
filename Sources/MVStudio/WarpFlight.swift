import Foundation

extension ImageEffects {
    struct WarpFlight: Codable, Equatable, Sendable {
        var isEnabled = true
        var speed = 100.0
        var zoom = 100.0
        var brightness = 100.0
        var opacity = 100.0
        var phaseOffset = 0.0

        static let parameters: [ImageParameter] = [.warpSpeed, .warpZoom, .warpBrightness, .warpOpacity]
        var isValid: Bool {
            let effects = ImageEffects(warpFlight: self)
            return Self.parameters.allSatisfy { parameter in
                guard let value = parameter.effect?.read(effects) else { return false }
                return parameter.accepts(value)
            } && phaseOffset.isFinite && abs(phaseOffset) < 1e12
        }
    }
}
