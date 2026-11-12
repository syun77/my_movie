import Foundation

extension ImageParameter {
    struct Effect {
        let title: String
        let unit: String
        let initial: Double
        let range: ClosedRange<Double>
        let read: (ImageEffects) -> Double?
        let write: (ImageEffects, Double) -> ImageEffects

        init<T>(_ title: String, _ unit: String, _ group: WritableKeyPath<ImageEffects, T?>,
                _ value: WritableKeyPath<T, Double>, _ initial: Double, _ range: ClosedRange<Double>) {
            self.title = title; self.unit = unit; self.initial = initial; self.range = range
            read = { $0[keyPath: group]?[keyPath: value] }
            write = { effects, number in
                var result = effects
                result[keyPath: group]?[keyPath: value] = number
                return result
            }
        }

        init(emitter index: Int, axis: WritableKeyPath<ImageEffects.Particles.Emitter, Double>, title: String,
             range: ClosedRange<Double>) {
            self.title = "発生源 \(index + 1) " + title; unit = "px"
            initial = ImageEffects.Particles.Emitter()[keyPath: axis]; self.range = range
            read = { effects in
                guard let emitters = effects.particles?.emitters, emitters.indices.contains(index) else { return nil }
                return emitters[index][keyPath: axis]
            }
            write = { effects, value in
                var result = effects
                if let emitters = result.particles?.emitters, emitters.indices.contains(index) {
                    result.particles?.emitters[index][keyPath: axis] = value
                }
                return result
            }
        }
    }

    var effect: Effect? {
        switch self {
        case .colorHue: return Effect("色調補正 色相", "°", \.colorCorrection, \.hue, ImageEffects.ColorCorrection().hue, ImageEffects.ColorCorrection.hueRange)
        case .colorBrightness: return Effect("色調補正 明度", "%", \.colorCorrection, \.brightness, ImageEffects.ColorCorrection().brightness, ImageEffects.ColorCorrection.brightnessRange)
        case .colorSaturation: return Effect("色調補正 彩度", "%", \.colorCorrection, \.saturation, ImageEffects.ColorCorrection().saturation, ImageEffects.ColorCorrection.saturationRange)
        case .shakeX: return Effect("シェイク X強さ", "px", \.shake, \.x, ImageEffects.Shake().x, ImageEffects.Shake.amplitudeRange)
        case .shakeY: return Effect("シェイク Y強さ", "px", \.shake, \.y, ImageEffects.Shake().y, ImageEffects.Shake.amplitudeRange)
        case .shakeStrength: return Effect("シェイク 総合強さ", "%", \.shake, \.strength, ImageEffects.Shake().strength, ImageEffects.Shake.strengthRange)
        case .blurRadius: return Effect("ブラー 半径", "px", \.blur, \.radius, ImageEffects.Blur().radius, ImageEffects.Blur.radiusRange)
        case .bloomThreshold: return Effect("ブルーム しきい値", "%", \.bloom, \.threshold, ImageEffects.Bloom().threshold, ImageEffects.Bloom.thresholdRange)
        case .bloomRadius: return Effect("ブルーム 半径", "px", \.bloom, \.radius, ImageEffects.Bloom().radius, ImageEffects.Bloom.radiusRange)
        case .bloomIntensity: return Effect("ブルーム 強さ", "%", \.bloom, \.intensity, ImageEffects.Bloom().intensity, ImageEffects.Bloom.intensityRange)
        case .particlesCount: return Effect("光の粒子 個数", "", \.particles, \.count, ImageEffects.Particles(seed: 0).count, ImageEffects.Particles.countRange)
        case .particlesDiameter: return Effect("光の粒子 直径", "px", \.particles, \.diameter, ImageEffects.Particles(seed: 0).diameter, ImageEffects.Particles.diameterRange)
        case .particlesSpeed: return Effect("光の粒子 速度", "px/秒", \.particles, \.speed, ImageEffects.Particles(seed: 0).speed, ImageEffects.Particles.speedRange)
        case .particlesCurveStrength: return Effect("光の粒子 曲線", "%", \.particles, \.curveStrength, ImageEffects.Particles(seed: 0).curveStrength, ImageEffects.Particles.curveStrengthRange)
        case .particlesOpacity: return Effect("光の粒子 不透明度", "%", \.particles, \.opacity, ImageEffects.Particles(seed: 0).opacity, ImageEffects.Particles.opacityRange)
        case .embersCount: return Effect("火の粉 個数", "", \.embers, \.count, ImageEffects.Embers(seed: 0).count, ImageEffects.Embers.countRange)
        case .embersDiameter: return Effect("火の粉 大きさ", "px", \.embers, \.diameter, ImageEffects.Embers(seed: 0).diameter, ImageEffects.Embers.diameterRange)
        case .embersRiseSpeed: return Effect("火の粉 上昇速度", "px/秒", \.embers, \.riseSpeed, ImageEffects.Embers(seed: 0).riseSpeed, ImageEffects.Embers.riseSpeedRange)
        case .embersWind: return Effect("火の粉 横風", "px/秒", \.embers, \.wind, ImageEffects.Embers(seed: 0).wind, ImageEffects.Embers.windRange)
        case .embersSwaySpeed: return Effect("火の粉 揺れ", "%", \.embers, \.swaySpeed, ImageEffects.Embers(seed: 0).swaySpeed, ImageEffects.Embers.swaySpeedRange)
        case .embersBrightness: return Effect("火の粉 明るさ", "%", \.embers, \.brightness, ImageEffects.Embers(seed: 0).brightness, ImageEffects.Embers.brightnessRange)
        case .snowCount: return Effect("雪 個数", "", \.snow, \.count, ImageEffects.Snow(seed: 0).count, ImageEffects.Snow.countRange)
        case .snowDiameter: return Effect("雪 大きさ", "px", \.snow, \.diameter, ImageEffects.Snow(seed: 0).diameter, ImageEffects.Snow.diameterRange)
        case .snowFallSpeed: return Effect("雪 落下速度", "px/秒", \.snow, \.fallSpeed, ImageEffects.Snow(seed: 0).fallSpeed, ImageEffects.Snow.fallSpeedRange)
        case .snowWind: return Effect("雪 横風", "%", \.snow, \.wind, ImageEffects.Snow(seed: 0).wind, ImageEffects.Snow.windRange)
        case .snowOpacity: return Effect("雪 不透明度", "%", \.snow, \.opacity, ImageEffects.Snow(seed: 0).opacity, ImageEffects.Snow.opacityRange)
        case .orbsCount: return Effect("光の粒子2 発生数", "", \.orbs, \.count, ImageEffects.Orbs().count, ImageEffects.Orbs.countRange)
        case .orbsSaturation: return Effect("光の粒子2 彩度", "%", \.orbs, \.saturation, ImageEffects.Orbs().saturation, ImageEffects.Orbs.saturationRange)
        case .orbsSpeed: return Effect("光の粒子2 速度", "%", \.orbs, \.speed, ImageEffects.Orbs().speed, ImageEffects.Orbs.speedRange)
        case .orbsOpacity: return Effect("光の粒子2 不透明度", "%", \.orbs, \.opacity, ImageEffects.Orbs().opacity, ImageEffects.Orbs.opacityRange)
        case .emitter0X: return Effect(emitter: 0, axis: \.x, title: "X", range: ImageEffects.Particles.Emitter.xRange)
        case .emitter0Y: return Effect(emitter: 0, axis: \.y, title: "Y", range: ImageEffects.Particles.Emitter.yRange)
        case .emitter1X: return Effect(emitter: 1, axis: \.x, title: "X", range: ImageEffects.Particles.Emitter.xRange)
        case .emitter1Y: return Effect(emitter: 1, axis: \.y, title: "Y", range: ImageEffects.Particles.Emitter.yRange)
        case .emitter2X: return Effect(emitter: 2, axis: \.x, title: "X", range: ImageEffects.Particles.Emitter.xRange)
        case .emitter2Y: return Effect(emitter: 2, axis: \.y, title: "Y", range: ImageEffects.Particles.Emitter.yRange)
        case .emitter3X: return Effect(emitter: 3, axis: \.x, title: "X", range: ImageEffects.Particles.Emitter.xRange)
        case .emitter3Y: return Effect(emitter: 3, axis: \.y, title: "Y", range: ImageEffects.Particles.Emitter.yRange)
        default: return nil
        }
    }
}

extension VisualClip {
    mutating func removeEmitterAutomation(at index: Int) {
        func movedParameter(_ parameter: ImageParameter) -> ImageParameter? {
            guard parameter.rawValue.hasPrefix("emitter"), let slot = Int(parameter.rawValue.dropFirst(7).prefix(1)) else { return parameter }
            if slot == index { return nil }
            if slot < index { return parameter }
            return ImageParameter(rawValue: "emitter\(slot - 1)" + parameter.rawValue.suffix(1))
        }
        audioModulations = Dictionary(uniqueKeysWithValues: audioModulations.compactMap { parameter, value in movedParameter(parameter).map { ($0, value) } })
        automationRanges = Dictionary(uniqueKeysWithValues: automationRanges.compactMap { parameter, value in movedParameter(parameter).map { ($0, value) } })
        curves = curves.compactMap { curve in
            guard curve.parameter.rawValue.hasPrefix("emitter"),
                  let slot = Int(curve.parameter.rawValue.dropFirst(7).prefix(1)) else { return curve }
            if slot == index { return nil }
            guard slot > index,
                  let parameter = ImageParameter(rawValue: "emitter\(slot - 1)" + curve.parameter.rawValue.suffix(1)) else { return curve }
            var moved = ImageCurve(parameter: parameter)
            moved.minimum = curve.minimum; moved.maximum = curve.maximum; moved.keys = curve.keys
            return moved
        }
    }

    func evaluatedEffects(at time: Double, settings: SceneSettings = SceneSettings(), features: AudioFeatures? = nil) -> ImageEffects? {
        guard var result = effects else { return nil }
        for parameter in automationParameters {
            guard let effect = parameter.effect, effect.read(result) != nil else { continue }
            let value = ParameterEvaluator.value(parameter, clip: self, at: time, settings: settings, features: features)
            result = effect.write(result, value)
        }
        return result
    }
}
