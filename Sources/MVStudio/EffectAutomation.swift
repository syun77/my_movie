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
        case .flareX: return Effect("レンズフレア 光源X", "px", \.lensFlare, \.x, 1440, -1920...3840)
        case .flareY: return Effect("レンズフレア 光源Y", "px", \.lensFlare, \.y, 270, -1080...2160)
        case .flareSize: return Effect("レンズフレア 大きさ", "%", \.lensFlare, \.size, 100, 25...400)
        case .flareIntensity: return Effect("レンズフレア 強さ", "%", \.lensFlare, \.intensity, 100, 0...200)
        case .radialSpeed: return Effect("集中線２ 速度", "%", \.radialFocus, \.speed, 100, 0...400)
        case .radialZoom: return Effect("集中線２ 拡大率", "%", \.radialFocus, \.zoom, 100, 25...400)
        case .radialBrightness: return Effect("集中線２ 明るさ", "%", \.radialFocus, \.brightness, 100, 0...200)
        case .radialOpacity: return Effect("集中線２ 不透明度", "%", \.radialFocus, \.opacity, 100, 0...100)
        case .zoomLoopCenterX: return Effect("拡大ループ 中心X", "px", \.zoomLoop, \.centerX, 960, 0...1920)
        case .zoomLoopCenterY: return Effect("拡大ループ 中心Y", "px", \.zoomLoop, \.centerY, 540, 0...1080)
        case .zoomLoopSpeed: return Effect("拡大ループ 速度", "%", \.zoomLoop, \.speed, 100, 0...400)
        case .zoomLoopZoom: return Effect("拡大ループ 拡大率", "%", \.zoomLoop, \.zoom, 100, 25...400)
        case .zoomLoopBrightness: return Effect("拡大ループ 明るさ", "%", \.zoomLoop, \.brightness, 100, 0...200)
        case .zoomLoopOpacity: return Effect("拡大ループ 不透明度", "%", \.zoomLoop, \.opacity, 100, 0...100)
        case .warpSpeed: return Effect("ワープ航行 速度", "%", \.warpFlight, \.speed, 100, 0...400)
        case .warpZoom: return Effect("ワープ航行 拡大率", "%", \.warpFlight, \.zoom, 100, 25...400)
        case .warpBrightness: return Effect("ワープ航行 明るさ", "%", \.warpFlight, \.brightness, 100, 0...200)
        case .warpOpacity: return Effect("ワープ航行 不透明度", "%", \.warpFlight, \.opacity, 100, 0...100)
        case .octSpeed: return Effect("八芒星 速度", "%", \.octgrams, \.speed, 100, 0...400)
        case .octZoom: return Effect("八芒星 拡大率", "%", \.octgrams, \.zoom, 100, 25...400)
        case .octBrightness: return Effect("八芒星 明るさ", "%", \.octgrams, \.brightness, 100, 0...200)
        case .octOpacity: return Effect("八芒星 不透明度", "%", \.octgrams, \.opacity, 100, 0...100)
        case .focusX: return Effect("集中線 中心X", "px", \.focusLines, \.x, ImageEffects.FocusLines(seed: 0).x, 0...1920)
        case .focusY: return Effect("集中線 中心Y", "px", \.focusLines, \.y, ImageEffects.FocusLines(seed: 0).y, 0...1080)
        case .focusWidth: return Effect("集中線 空白の幅", "px", \.focusLines, \.width, ImageEffects.FocusLines(seed: 0).width, 0...3840)
        case .focusHeight: return Effect("集中線 空白の高さ", "px", \.focusLines, \.height, ImageEffects.FocusLines(seed: 0).height, 0...2160)
        case .focusCount: return Effect("集中線 本数", "", \.focusLines, \.count, ImageEffects.FocusLines(seed: 0).count, 8...300)
        case .focusThickness: return Effect("集中線 太さ", "px", \.focusLines, \.thickness, ImageEffects.FocusLines(seed: 0).thickness, 1...40)
        case .focusLength: return Effect("集中線 長さ", "%", \.focusLines, \.length, ImageEffects.FocusLines(seed: 0).length, 0...100)
        case .focusVariation: return Effect("集中線 ばらつき", "%", \.focusLines, \.variation, ImageEffects.FocusLines(seed: 0).variation, 0...100)
        case .focusOpacity: return Effect("集中線 不透明度", "%", \.focusLines, \.opacity, ImageEffects.FocusLines(seed: 0).opacity, 0...100)
        case .shapeWidth: return Effect("図形 幅", "px", \.shape, \.geometry.width, ShapeGeometry().width, ShapeGeometry.sizeRange)
        case .shapeHeight: return Effect("図形 高さ", "px", \.shape, \.geometry.height, ShapeGeometry().height, ShapeGeometry.sizeRange)
        case .shapeX: return Effect("図形 中心X", "px", \.shape, \.geometry.x, ShapeGeometry().x, ShapeGeometry.positionRange)
        case .shapeY: return Effect("図形 中心Y", "px", \.shape, \.geometry.y, ShapeGeometry().y, ShapeGeometry.positionRange)
        case .shapeRotation: return Effect("図形 回転", "°", \.shape, \.geometry.rotation, ShapeGeometry().rotation, ShapeGeometry.rotationRange)
        case .shapeInnerRatio: return Effect("図形 星の内径比", "%", \.shape, \.geometry.innerRatio, ShapeGeometry().innerRatio, ShapeGeometry.innerRatioRange)
        case .shapeOpacity: return Effect("図形 不透明度", "%", \.shape, \.opacity, ImageEffects.Shape().opacity, 0...100)
        case .maskWidth: return Effect("マスク 幅", "px", \.mask, \.geometry.width, ShapeGeometry().width, ShapeGeometry.sizeRange)
        case .maskHeight: return Effect("マスク 高さ", "px", \.mask, \.geometry.height, ShapeGeometry().height, ShapeGeometry.sizeRange)
        case .maskX: return Effect("マスク 中心X", "px", \.mask, \.geometry.x, ShapeGeometry().x, ShapeGeometry.positionRange)
        case .maskY: return Effect("マスク 中心Y", "px", \.mask, \.geometry.y, ShapeGeometry().y, ShapeGeometry.positionRange)
        case .maskRotation: return Effect("マスク 回転", "°", \.mask, \.geometry.rotation, ShapeGeometry().rotation, ShapeGeometry.rotationRange)
        case .maskInnerRatio: return Effect("マスク 星の内径比", "%", \.mask, \.geometry.innerRatio, ShapeGeometry().innerRatio, ShapeGeometry.innerRatioRange)
        case .maskFeather: return Effect("マスク 境界ぼかし", "px", \.mask, \.feather, ImageEffects.Mask().feather, 0...200)
        case .maskStrength: return Effect("マスク 強さ", "%", \.mask, \.strength, ImageEffects.Mask().strength, 0...100)
        case .vignetteStrength: return Effect("Vignette 強さ", "%", \.vignette, \.strength, ImageEffects.Vignette().strength, ImageEffects.Vignette.percentRange)
        case .vignetteSize: return Effect("Vignette 範囲", "%", \.vignette, \.size, ImageEffects.Vignette().size, ImageEffects.Vignette.percentRange)
        case .vignetteSoftness: return Effect("Vignette ぼかし", "%", \.vignette, \.softness, ImageEffects.Vignette().softness, ImageEffects.Vignette.percentRange)
        case .chromaticAmount: return Effect("色収差 ずれ量", "px", \.chromaticAberration, \.amount, ImageEffects.ChromaticAberration().amount, ImageEffects.ChromaticAberration.amountRange)
        case .chromaticAngle: return Effect("色収差 角度", "°", \.chromaticAberration, \.angle, ImageEffects.ChromaticAberration().angle, ImageEffects.ChromaticAberration.angleRange)
        case .colorHue: return Effect("色調補正 色相", "°", \.colorCorrection, \.hue, ImageEffects.ColorCorrection().hue, ImageEffects.ColorCorrection.hueRange)
        case .colorBrightness: return Effect("色調補正 明度", "%", \.colorCorrection, \.brightness, ImageEffects.ColorCorrection().brightness, ImageEffects.ColorCorrection.brightnessRange)
        case .colorSaturation: return Effect("色調補正 彩度", "%", \.colorCorrection, \.saturation, ImageEffects.ColorCorrection().saturation, ImageEffects.ColorCorrection.saturationRange)
        case .shakeX: return Effect("シェイク X強さ", "px", \.shake, \.x, ImageEffects.Shake().x, ImageEffects.Shake.amplitudeRange)
        case .shakeY: return Effect("シェイク Y強さ", "px", \.shake, \.y, ImageEffects.Shake().y, ImageEffects.Shake.amplitudeRange)
        case .shakeStrength: return Effect("シェイク 総合強さ", "%", \.shake, \.strength, ImageEffects.Shake().strength, ImageEffects.Shake.strengthRange)
        case .blurRadius: return Effect("ブラー 半径", "px", \.blur, \.radius, ImageEffects.Blur().radius, ImageEffects.Blur.radiusRange)
        case .glareThreshold: return Effect("クロスグレア しきい値", "%", \.crossGlare, \.threshold, ImageEffects.CrossGlare().threshold, ImageEffects.CrossGlare.thresholdRange)
        case .glareIntensity: return Effect("クロスグレア 強さ", "%", \.crossGlare, \.intensity, ImageEffects.CrossGlare().intensity, ImageEffects.CrossGlare.intensityRange)
        case .glareLength: return Effect("クロスグレア 長さ", "px", \.crossGlare, \.length, ImageEffects.CrossGlare().length, ImageEffects.CrossGlare.lengthRange)
        case .glareWidth: return Effect("クロスグレア 太さ", "px", \.crossGlare, \.width, ImageEffects.CrossGlare().width, ImageEffects.CrossGlare.widthRange)
        case .glareAngle: return Effect("クロスグレア 角度", "°", \.crossGlare, \.angle, ImageEffects.CrossGlare().angle, ImageEffects.CrossGlare.angleRange)
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
