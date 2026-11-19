import Foundation

extension ImageEffects {
    struct SobelChromatic: Codable, Equatable, Sendable {
        enum Mode: String, Codable, CaseIterable, Sendable {
            case automatic, edge, chromatic, combined
            var title: String {
                switch self {
                case .automatic: return "自動切替"
                case .edge: return "輪郭"
                case .chromatic: return "色収差"
                case .combined: return "合成"
                }
            }
        }
        static let parameters: [ImageParameter] = [.sobelAmount, .sobelStrength, .sobelWidth, .sobelChromaticAmount, .sobelSpeed]
        static let amountRange = 0.0...100
        static let strengthRange = 0.0...400
        static let widthRange = 0.25...8
        static let chromaticRange = 0.0...100
        static let speedRange = 0.0...400
        var isEnabled = true
        var mode = Mode.automatic
        var amount = 100.0
        var edgeStrength = 100.0
        var edgeWidth = 1.0
        var edgeColor = RGBColor(red: 0.20, green: 0.85, blue: 1)
        var chromaticAmount = 32.0
        var speed = 100.0
        var phaseOffset = 0.0

        var isValid: Bool {
            Self.amountRange.contains(amount) && Self.strengthRange.contains(edgeStrength) && Self.widthRange.contains(edgeWidth)
                && Self.chromaticRange.contains(chromaticAmount) && Self.speedRange.contains(speed)
                && [amount, edgeStrength, edgeWidth, chromaticAmount, speed].allSatisfy(\.isFinite)
                && edgeColor.isValid && phaseOffset.isFinite && abs(phaseOffset) < 1e12
        }

        func uses(_ parameter: ImageParameter) -> Bool {
            switch parameter {
            case .sobelStrength, .sobelWidth: return mode != .chromatic
            case .sobelChromaticAmount: return mode != .edge
            default: return true
            }
        }

        struct Sample {
            let mode: Mode
            let negativeOffset: Double
            let positiveOffset: Double
            let displacement: Double
            let blueDirection: Double
            var hasEdge: Bool { mode == .edge || mode == .combined }
            var hasChromatic: Bool { mode == .chromatic || mode == .combined }
            var support: Double {
                max(hasEdge ? max(abs(negativeOffset), abs(positiveOffset)) : 0,
                    hasChromatic ? displacement : 0) + 1
            }
        }

        func sample(at localTime: Double) -> Sample {
            let time = (localTime + phaseOffset) * speed / 100
            let pulse = sin(2 * time)
            let resolved = mode == .automatic ? (pulse > 0.4 && pulse < 0.8 ? Mode.edge : .chromatic) : mode
            let oscillation = 1.8 * cos(6 * time)
            return Sample(mode: resolved, negativeOffset: -oscillation * edgeWidth,
                          positiveOffset: 3.2 * sin(6 * time) * edgeWidth,
                          displacement: abs(pulse) * chromaticAmount, blueDirection: oscillation / sqrt(10))
        }
    }
}
