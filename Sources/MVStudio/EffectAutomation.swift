import Foundation

extension ImageParameter {
    struct Effect {
        let title: String
        let unit: String
        let initial: Double
        let range: ClosedRange<Double>
        let read: (ImageEffects) -> Double?
        let write: (ImageEffects, Double) -> ImageEffects

        init(particle kind: EffectKind, field: WritableKeyPath<ParticleAppearance, Double>, title: String,
             unit: String, initial: Double, range: ClosedRange<Double>) {
            self.title = kind.title + " " + title; self.unit = unit; self.initial = initial; self.range = range
            read = { $0.appearance(kind)?[keyPath: field] }
            write = { effects, value in
                var result = effects
                if var appearance = result.appearance(kind) {
                    appearance[keyPath: field] = value; result.setAppearance(appearance, for: kind)
                }
                return result
            }
        }

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
        if let field = ImageEffects.SpiralParticles.fieldsByParameter[self] {
            return Effect("渦巻き粒子 " + field.title, field.unit, \.spiralParticles, field.path,
                          ImageEffects.SpiralParticles(seed: 0)[keyPath: field.path], field.range)
        }
        if let field = ImageEffects.GradientBackground.fieldsByParameter[self] {
            return Effect("グラデーション背景 " + field.title, field.unit, \.gradientBackground, field.path,
                          ImageEffects.GradientBackground()[keyPath: field.path], field.range)
        }
        if let field = ImageEffects.ElectricBeam.fieldsByParameter[self] {
            return Effect("電撃ビーム " + field.title, field.unit, \.electricBeam, field.path,
                          ImageEffects.ElectricBeam(seed: 0)[keyPath: field.path], field.range)
        }
        if let field = ImageEffects.FireOutline.fieldsByParameter[self] {
            return Effect("炎アウトライン " + field.title, field.unit, \.fireOutline, field.path,
                          ImageEffects.FireOutline()[keyPath: field.path], field.range)
        }
        switch self {
        case .particlesImageSize: return Effect(particle: .particles, field: \.size, title: "画像の大きさ", unit: "px", initial: 32, range: 1...1000)
        case .particlesImageAngle: return Effect(particle: .particles, field: \.angle, title: "画像の角度", unit: "°", initial: 0, range: -180...180)
        case .particlesImageSpread: return Effect(particle: .particles, field: \.spread, title: "回転ばらつき", unit: "°", initial: 0, range: 0...180)
        case .particlesImageSpin: return Effect(particle: .particles, field: \.spin, title: "回転速度", unit: "°/秒", initial: 0, range: -360...360)
        case .embersImageSize: return Effect(particle: .embers, field: \.size, title: "画像の大きさ", unit: "px", initial: 32, range: 1...1000)
        case .embersImageAngle: return Effect(particle: .embers, field: \.angle, title: "画像の角度", unit: "°", initial: 0, range: -180...180)
        case .embersImageSpread: return Effect(particle: .embers, field: \.spread, title: "回転ばらつき", unit: "°", initial: 0, range: 0...180)
        case .embersImageSpin: return Effect(particle: .embers, field: \.spin, title: "回転速度", unit: "°/秒", initial: 0, range: -360...360)
        case .snowImageSize: return Effect(particle: .snow, field: \.size, title: "画像の大きさ", unit: "px", initial: 32, range: 1...1000)
        case .snowImageAngle: return Effect(particle: .snow, field: \.angle, title: "画像の角度", unit: "°", initial: 0, range: -180...180)
        case .snowImageSpread: return Effect(particle: .snow, field: \.spread, title: "回転ばらつき", unit: "°", initial: 0, range: 0...180)
        case .snowImageSpin: return Effect(particle: .snow, field: \.spin, title: "回転速度", unit: "°/秒", initial: 0, range: -360...360)
        case .spiralImageSize: return Effect(particle: .spiralParticles, field: \.size, title: "画像の大きさ", unit: "px", initial: 32, range: 1...1000)
        case .orbsImageSize: return Effect(particle: .orbs, field: \.size, title: "画像の大きさ", unit: "px", initial: 32, range: 1...1000)
        case .spiralImageAngle: return Effect(particle: .spiralParticles, field: \.angle, title: "画像の角度", unit: "°", initial: 0, range: -180...180)
        case .orbsImageAngle: return Effect(particle: .orbs, field: \.angle, title: "画像の角度", unit: "°", initial: 0, range: -180...180)
        case .spiralImageSpread: return Effect(particle: .spiralParticles, field: \.spread, title: "回転ばらつき", unit: "°", initial: 0, range: 0...180)
        case .orbsImageSpread: return Effect(particle: .orbs, field: \.spread, title: "回転ばらつき", unit: "°", initial: 0, range: 0...180)
        case .spiralImageSpin: return Effect(particle: .spiralParticles, field: \.spin, title: "回転速度", unit: "°/秒", initial: 0, range: -360...360)
        case .orbsImageSpin: return Effect(particle: .orbs, field: \.spin, title: "回転速度", unit: "°/秒", initial: 0, range: -360...360)
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
        case .raysX: return Effect("放射光線 中心X", "px", \.radialRays, \.x, 960, 0...1920)
        case .raysY: return Effect("放射光線 中心Y", "px", \.radialRays, \.y, 540, 0...1080)
        case .raysLength: return Effect("放射光線 中心からの長さ", "px", \.radialRays, \.length, 1440, 1...7680)
        case .raysSquash: return Effect("放射光線 潰れ具合", "%", \.radialRays, \.squash, 43.75, -99...99)
        case .raysCount: return Effect("放射光線 本数", "", \.radialRays, \.count, 16, 1...128)
        case .raysThickness: return Effect("放射光線 太さ", "°", \.radialRays, \.thickness, 5, 0.2...20)
        case .raysLengthVariation: return Effect("放射光線 長さのばらつき", "%", \.radialRays, \.lengthVariation, 35, 0...100)
        case .raysVariation: return Effect("放射光線 形状のばらつき", "%", \.radialRays, \.variation, 70, 0...100)
        case .raysFlicker: return Effect("放射光線 明滅の強さ", "%", \.radialRays, \.flicker, 65, 0...100)
        case .raysIntensity: return Effect("放射光線 光量", "%", \.radialRays, \.intensity, 100, 0...300)
        case .raysGlow: return Effect("放射光線 にじみ", "px", \.radialRays, \.glow, 18, 0...100)
        case .raysCoreSize: return Effect("放射光線 中心光のサイズ", "px", \.radialRays, \.coreSize, 120, 0...1080)
        case .raysCoreIntensity: return Effect("放射光線 中心光の強さ", "%", \.radialRays, \.coreIntensity, 100, 0...300)
        case .raysOpacity: return Effect("放射光線 不透明度", "%", \.radialRays, \.opacity, 100, 0...100)
        case .straightAngle: return Effect("直線効果線 角度", "°", \.straightLines, \.angle, 0, -180...180)
        case .straightCount: return Effect("直線効果線 表示本数", "", \.straightLines, \.count, 40, 0...300)
        case .straightLength: return Effect("直線効果線 長さ", "px", \.straightLines, \.length, 800, 10...3840)
        case .straightThickness: return Effect("直線効果線 太さ", "px", \.straightLines, \.thickness, 2, 0.5...30)
        case .straightSpeed: return Effect("直線効果線 移動速度", "px/秒", \.straightLines, \.speed, 1600, 0...8000)
        case .straightLengthVariation: return Effect("直線効果線 長さのばらつき", "%", \.straightLines, \.lengthVariation, 65, 0...100)
        case .straightThicknessVariation: return Effect("直線効果線 太さのばらつき", "%", \.straightLines, \.thicknessVariation, 50, 0...100)
        case .straightToneVariation: return Effect("直線効果線 不透明度のばらつき", "%", \.straightLines, \.toneVariation, 60, 0...100)
        case .straightFade: return Effect("直線効果線 端のフェード", "%", \.straightLines, \.fade, 15, 0...50)
        case .straightGlow: return Effect("直線効果線 発光", "%", \.straightLines, \.glow, 25, 0...200)
        case .straightOpacity: return Effect("直線効果線 不透明度", "%", \.straightLines, \.opacity, 80, 0...100)
        case .sharpX: return Effect("集中線３ 中心X", "px", \.sharpFocus, \.x, ImageEffects.SharpFocus(seed: 0).x, 0...1920)
        case .sharpY: return Effect("集中線３ 中心Y", "px", \.sharpFocus, \.y, ImageEffects.SharpFocus(seed: 0).y, 0...1080)
        case .sharpWidth: return Effect("集中線３ 内端の分布幅", "px", \.sharpFocus, \.width, ImageEffects.SharpFocus(seed: 0).width, 0...3840)
        case .sharpHeight: return Effect("集中線３ 内端の分布高さ", "px", \.sharpFocus, \.height, ImageEffects.SharpFocus(seed: 0).height, 0...2160)
        case .sharpCount: return Effect("集中線３ 本数", "", \.sharpFocus, \.count, ImageEffects.SharpFocus(seed: 0).count, 8...300)
        case .sharpThickness: return Effect("集中線３ 太さ", "px", \.sharpFocus, \.thickness, ImageEffects.SharpFocus(seed: 0).thickness, 1...40)
        case .sharpLength: return Effect("集中線３ 長さ", "%", \.sharpFocus, \.length, ImageEffects.SharpFocus(seed: 0).length, 0...100)
        case .sharpVariation: return Effect("集中線３ ばらつき", "%", \.sharpFocus, \.variation, ImageEffects.SharpFocus(seed: 0).variation, 0...100)
        case .sharpOpacity: return Effect("集中線３ 不透明度", "%", \.sharpFocus, \.opacity, ImageEffects.SharpFocus(seed: 0).opacity, 0...100)
        case .sharpTipLength: return Effect("集中線３ 先端の長さ", "px", \.sharpFocus, \.tipLength, 12, 0...80)
        case .sharpToneVariation: return Effect("集中線３ 不透明度のばらつき", "%", \.sharpFocus, \.toneVariation, 65, 0...100)
        case .shapeWidth: return Effect("図形 幅", "px", \.shape, \.geometry.width, ShapeGeometry().width, ShapeGeometry.sizeRange)
        case .shapeHeight: return Effect("図形 高さ", "px", \.shape, \.geometry.height, ShapeGeometry().height, ShapeGeometry.sizeRange)
        case .shapeX: return Effect("図形 中心X", "px", \.shape, \.geometry.x, ShapeGeometry().x, ShapeGeometry.positionRange)
        case .shapeY: return Effect("図形 中心Y", "px", \.shape, \.geometry.y, ShapeGeometry().y, ShapeGeometry.positionRange)
        case .shapeRotation: return Effect("図形 回転", "°", \.shape, \.geometry.rotation, ShapeGeometry().rotation, ShapeGeometry.rotationRange)
        case .shapeInnerRatio: return Effect("図形 星の内径比", "%", \.shape, \.geometry.innerRatio, ShapeGeometry().innerRatio, ShapeGeometry.innerRatioRange)
        case .shapeOpacity: return Effect("図形 不透明度", "%", \.shape, \.opacity, ImageEffects.Shape().opacity, 0...100)
        case .belowMaskWidth: return Effect("直下段マスク 幅", "px", \.belowMask, \.geometry.width, ShapeGeometry().width, ShapeGeometry.sizeRange)
        case .belowMaskHeight: return Effect("直下段マスク 高さ", "px", \.belowMask, \.geometry.height, ShapeGeometry().height, ShapeGeometry.sizeRange)
        case .belowMaskX: return Effect("直下段マスク 中心X", "px", \.belowMask, \.geometry.x, ShapeGeometry().x, ShapeGeometry.positionRange)
        case .belowMaskY: return Effect("直下段マスク 中心Y", "px", \.belowMask, \.geometry.y, ShapeGeometry().y, ShapeGeometry.positionRange)
        case .belowMaskRotation: return Effect("直下段マスク 回転", "°", \.belowMask, \.geometry.rotation, ShapeGeometry().rotation, ShapeGeometry.rotationRange)
        case .belowMaskInnerRatio: return Effect("直下段マスク 星の内径比", "%", \.belowMask, \.geometry.innerRatio, ShapeGeometry().innerRatio, ShapeGeometry.innerRatioRange)
        case .belowMaskFeather: return Effect("直下段マスク 境界ぼかし", "px", \.belowMask, \.feather, ImageEffects.Mask().feather, 0...200)
        case .belowMaskStrength: return Effect("直下段マスク 強さ", "%", \.belowMask, \.strength, ImageEffects.Mask().strength, 0...100)
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
        case .sobelAmount: return Effect("Sobel 適用率", "%", \.sobelChromatic, \.amount, ImageEffects.SobelChromatic().amount, ImageEffects.SobelChromatic.amountRange)
        case .sobelStrength: return Effect("Sobel 輪郭の強さ", "%", \.sobelChromatic, \.edgeStrength, ImageEffects.SobelChromatic().edgeStrength, ImageEffects.SobelChromatic.strengthRange)
        case .sobelWidth: return Effect("Sobel 輪郭の幅", "px", \.sobelChromatic, \.edgeWidth, ImageEffects.SobelChromatic().edgeWidth, ImageEffects.SobelChromatic.widthRange)
        case .sobelChromaticAmount: return Effect("Sobel 色ずれ量", "px", \.sobelChromatic, \.chromaticAmount, ImageEffects.SobelChromatic().chromaticAmount, ImageEffects.SobelChromatic.chromaticRange)
        case .sobelSpeed: return Effect("Sobel 動きの速さ", "%", \.sobelChromatic, \.speed, ImageEffects.SobelChromatic().speed, ImageEffects.SobelChromatic.speedRange)
        case .chromaticAmount: return Effect("色収差 ずれ量", "px", \.chromaticAberration, \.amount, ImageEffects.ChromaticAberration().amount, ImageEffects.ChromaticAberration.amountRange)
        case .chromaticAngle: return Effect("色収差 角度", "°", \.chromaticAberration, \.angle, ImageEffects.ChromaticAberration().angle, ImageEffects.ChromaticAberration.angleRange)
        case .binarizationThreshold: return Effect("2値化 しきい値", "%", \.binarization, \.threshold, ImageEffects.Binarization().threshold, ImageEffects.Binarization.percentRange)
        case .binarizationAmount: return Effect("2値化 適用率", "%", \.binarization, \.amount, ImageEffects.Binarization().amount, ImageEffects.Binarization.percentRange)
        case .colorHue: return Effect("色調補正 色相", "°", \.colorCorrection, \.hue, ImageEffects.ColorCorrection().hue, ImageEffects.ColorCorrection.hueRange)
        case .colorBrightness: return Effect("色調補正 明度", "%", \.colorCorrection, \.brightness, ImageEffects.ColorCorrection().brightness, ImageEffects.ColorCorrection.brightnessRange)
        case .colorSaturation: return Effect("色調補正 彩度", "%", \.colorCorrection, \.saturation, ImageEffects.ColorCorrection().saturation, ImageEffects.ColorCorrection.saturationRange)
        case .shakeX: return Effect("シェイク X強さ", "px", \.shake, \.x, ImageEffects.Shake().x, ImageEffects.Shake.amplitudeRange)
        case .shakeY: return Effect("シェイク Y強さ", "px", \.shake, \.y, ImageEffects.Shake().y, ImageEffects.Shake.amplitudeRange)
        case .shakeStrength: return Effect("シェイク 総合強さ", "%", \.shake, \.strength, ImageEffects.Shake().strength, ImageEffects.Shake.strengthRange)
        case .radialBlurStrength: return Effect("放射ブラー 強さ", "%", \.radialBlur, \.strength, 0, 0...100)
        case .radialBlurSampleCount: return Effect("放射ブラー 最大サンプル回数", "", \.radialBlur, \.sampleCount, 256, 2...256)
        case .radialBlurX: return Effect("放射ブラー 中心X", "px", \.radialBlur, \.centerX, 960, 0...1920)
        case .radialBlurY: return Effect("放射ブラー 中心Y", "px", \.radialBlur, \.centerY, 540, 0...1080)
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
        automations = automations.compactMap { item in
            guard let parameter = movedParameter(item.parameter) else { return nil }
            var moved = item; moved.parameter = parameter; return moved
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
