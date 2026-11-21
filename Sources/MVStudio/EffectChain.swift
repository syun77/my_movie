import Foundation

/// Stable node identity owns parameters and automation independently of the processing order.
struct EffectNode: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var particleAppearance: ParticleAppearance?
    var payload: EffectPayload
    var automations: [ParameterAutomation] = []
    var curves: [ImageCurve] {
        get { AutomationCurves.curves(automations, ranges: automationRanges) }
        set { AutomationCurves.update(newValue, items: &automations, ranges: &automationRanges) }
    }
    var audioModulations: [ImageParameter: AudioModulation] = [:]
    var automationRanges: [ImageParameter: VisualClip.DisplayRange] = [:]
    var kind: EffectKind { payload.kind }
    var isEnabled: Bool {
        get { payload.isEnabled }
        set { payload.isEnabled = newValue }
    }
}

enum EffectKind: Int, CaseIterable, Codable, Sendable {
    case shape
    case mask
    case solidBackground
    case blur
    case radialBlur
    case crossGlare
    case bloom
    case particles
    case embers
    case snow
    case orbs
    case zoomLoop
    case octgrams
    case warpFlight
    case radialFocus
    case radialRays
    case straightLines
    case sharpFocus
    case focusLines
    case shake
    case binarization
    case colorCorrection
    case chromaticAberration
    case lensFlare
    case vignette
    case belowMask
    case sobelChromatic
    case fireOutline
    case electricBeam
    case gradientBackground
    case spiralParticles
    var title: String {
        switch self {
        case .shape: return "図形"
        case .mask: return "このクリップのマスク"
        case .spiralParticles: return "渦巻き粒子"
        case .gradientBackground: return "グラデーション背景"
        case .solidBackground: return "単色背景"
        case .blur: return "ガウスブラー"
        case .radialBlur: return "放射ブラー"
        case .crossGlare: return "クロスグレア"
        case .bloom: return "ブルーム"
        case .particles: return "光の粒子"
        case .embers: return "舞い上がる火の粉"
        case .snow: return "雪"
        case .orbs: return "光の粒子2"
        case .zoomLoop: return "拡大ループ"
        case .octgrams: return "八芒星"
        case .warpFlight: return "ワープ航行"
        case .radialFocus: return "集中線２"
        case .radialRays: return "放射光線"
        case .straightLines: return "直線効果線"
        case .sharpFocus: return "集中線３"
        case .focusLines: return "集中線"
        case .shake: return "シェイク"
        case .binarization: return "2値化"
        case .colorCorrection: return "色調補正"
        case .chromaticAberration: return "色収差"
        case .lensFlare: return "レンズフレア"
        case .electricBeam: return "電撃ビーム"
        case .fireOutline: return "炎アウトライン"
        case .sobelChromatic: return "Sobel＋色収差"
        case .vignette: return "Vignette（周辺減光）"
        case .belowMask: return "直下段のマスク"
        }
    }
    func exists(in effects: ImageEffects) -> Bool { effects.allNodes.contains { $0.kind == self } }
    var initial: EffectPayload {
        switch self {
        case .shape: return .shape(.init())
        case .mask: return .mask(.init())
        case .spiralParticles: return .spiralParticles(.init())
        case .gradientBackground: return .gradientBackground(.init())
        case .solidBackground: return .solidBackground(.init())
        case .blur: return .blur(.init())
        case .radialBlur: return .radialBlur(.init())
        case .crossGlare: return .crossGlare(.init())
        case .bloom: return .bloom(.init())
        case .particles: return .particles(.init())
        case .embers: return .embers(.init())
        case .snow: return .snow(.init())
        case .orbs: return .orbs(.init())
        case .zoomLoop: return .zoomLoop(.init())
        case .octgrams: return .octgrams(.init())
        case .warpFlight: return .warpFlight(.init())
        case .radialFocus: return .radialFocus(.init())
        case .radialRays: return .radialRays(.init())
        case .straightLines: return .straightLines(.init())
        case .sharpFocus: return .sharpFocus(.init())
        case .focusLines: return .focusLines(.init())
        case .shake: return .shake(.init())
        case .binarization: return .binarization(.init())
        case .colorCorrection: return .colorCorrection(.init())
        case .chromaticAberration: return .chromaticAberration(.init())
        case .lensFlare: return .lensFlare(.init())
        case .electricBeam: return .electricBeam(.init())
        case .fireOutline: return .fireOutline(.init())
        case .sobelChromatic: return .sobelChromatic(.init())
        case .vignette: return .vignette(.init())
        case .belowMask: return .belowMask(.init())
        }
    }
}

enum EffectPayload: Codable, Equatable, Sendable {
    case shape(ImageEffects.Shape)
    case mask(ImageEffects.Mask)
    case spiralParticles(ImageEffects.SpiralParticles)
    case gradientBackground(ImageEffects.GradientBackground)
    case solidBackground(ImageEffects.SolidBackground)
    case blur(ImageEffects.Blur)
    case radialBlur(ImageEffects.RadialBlur)
    case crossGlare(ImageEffects.CrossGlare)
    case bloom(ImageEffects.Bloom)
    case particles(ImageEffects.Particles)
    case embers(ImageEffects.Embers)
    case snow(ImageEffects.Snow)
    case orbs(ImageEffects.Orbs)
    case zoomLoop(ImageEffects.ZoomLoop)
    case octgrams(ImageEffects.Octgrams)
    case warpFlight(ImageEffects.WarpFlight)
    case radialFocus(ImageEffects.RadialFocus)
    case radialRays(ImageEffects.RadialRays)
    case straightLines(ImageEffects.StraightLines)
    case sharpFocus(ImageEffects.SharpFocus)
    case focusLines(ImageEffects.FocusLines)
    case shake(ImageEffects.Shake)
    case binarization(ImageEffects.Binarization)
    case colorCorrection(ImageEffects.ColorCorrection)
    case chromaticAberration(ImageEffects.ChromaticAberration)
    case lensFlare(ImageEffects.LensFlare)
    case electricBeam(ImageEffects.ElectricBeam)
    case fireOutline(ImageEffects.FireOutline)
    case sobelChromatic(ImageEffects.SobelChromatic)
    case vignette(ImageEffects.Vignette)
    case belowMask(ImageEffects.Mask)
    var kind: EffectKind {
        switch self {
        case .shape: return .shape
        case .mask: return .mask
        case .spiralParticles: return .spiralParticles
        case .gradientBackground: return .gradientBackground
        case .solidBackground: return .solidBackground
        case .blur: return .blur
        case .radialBlur: return .radialBlur
        case .crossGlare: return .crossGlare
        case .bloom: return .bloom
        case .particles: return .particles
        case .embers: return .embers
        case .snow: return .snow
        case .orbs: return .orbs
        case .zoomLoop: return .zoomLoop
        case .octgrams: return .octgrams
        case .warpFlight: return .warpFlight
        case .radialFocus: return .radialFocus
        case .radialRays: return .radialRays
        case .straightLines: return .straightLines
        case .sharpFocus: return .sharpFocus
        case .focusLines: return .focusLines
        case .shake: return .shake
        case .binarization: return .binarization
        case .colorCorrection: return .colorCorrection
        case .chromaticAberration: return .chromaticAberration
        case .lensFlare: return .lensFlare
        case .electricBeam: return .electricBeam
        case .fireOutline: return .fireOutline
        case .sobelChromatic: return .sobelChromatic
        case .vignette: return .vignette
        case .belowMask: return .belowMask
        }
    }
    var isEnabled: Bool {
        get {
            switch self {
            case let .shape(value): return value.isEnabled
            case let .mask(value): return value.isEnabled
            case let .spiralParticles(value): return value.isEnabled
            case let .gradientBackground(value): return value.isEnabled
            case let .solidBackground(value): return value.isEnabled
            case let .blur(value): return value.isEnabled
            case let .radialBlur(value): return value.isEnabled
            case let .crossGlare(value): return value.isEnabled
            case let .bloom(value): return value.isEnabled
            case let .particles(value): return value.isEnabled
            case let .embers(value): return value.isEnabled
            case let .snow(value): return value.isEnabled
            case let .orbs(value): return value.isEnabled
            case let .zoomLoop(value): return value.isEnabled
            case let .octgrams(value): return value.isEnabled
            case let .warpFlight(value): return value.isEnabled
            case let .radialFocus(value): return value.isEnabled
            case let .radialRays(value): return value.isEnabled
            case let .straightLines(value): return value.isEnabled
            case let .sharpFocus(value): return value.isEnabled
            case let .focusLines(value): return value.isEnabled
            case let .shake(value): return value.isEnabled
            case let .binarization(value): return value.isEnabled
            case let .colorCorrection(value): return value.isEnabled
            case let .chromaticAberration(value): return value.isEnabled
            case let .lensFlare(value): return value.isEnabled
            case let .electricBeam(value): return value.isEnabled
            case let .fireOutline(value): return value.isEnabled
            case let .sobelChromatic(value): return value.isEnabled
            case let .vignette(value): return value.isEnabled
            case let .belowMask(value): return value.isEnabled
            }
        }
        set {
            switch self {
            case var .shape(value): value.isEnabled = newValue; self = .shape(value)
            case var .mask(value): value.isEnabled = newValue; self = .mask(value)
            case var .spiralParticles(value): value.isEnabled = newValue; self = .spiralParticles(value)
            case var .gradientBackground(value): value.isEnabled = newValue; self = .gradientBackground(value)
            case var .solidBackground(value): value.isEnabled = newValue; self = .solidBackground(value)
            case var .blur(value): value.isEnabled = newValue; self = .blur(value)
            case var .radialBlur(value): value.isEnabled = newValue; self = .radialBlur(value)
            case var .crossGlare(value): value.isEnabled = newValue; self = .crossGlare(value)
            case var .bloom(value): value.isEnabled = newValue; self = .bloom(value)
            case var .particles(value): value.isEnabled = newValue; self = .particles(value)
            case var .embers(value): value.isEnabled = newValue; self = .embers(value)
            case var .snow(value): value.isEnabled = newValue; self = .snow(value)
            case var .orbs(value): value.isEnabled = newValue; self = .orbs(value)
            case var .zoomLoop(value): value.isEnabled = newValue; self = .zoomLoop(value)
            case var .octgrams(value): value.isEnabled = newValue; self = .octgrams(value)
            case var .warpFlight(value): value.isEnabled = newValue; self = .warpFlight(value)
            case var .radialFocus(value): value.isEnabled = newValue; self = .radialFocus(value)
            case var .radialRays(value): value.isEnabled = newValue; self = .radialRays(value)
            case var .straightLines(value): value.isEnabled = newValue; self = .straightLines(value)
            case var .sharpFocus(value): value.isEnabled = newValue; self = .sharpFocus(value)
            case var .focusLines(value): value.isEnabled = newValue; self = .focusLines(value)
            case var .shake(value): value.isEnabled = newValue; self = .shake(value)
            case var .binarization(value): value.isEnabled = newValue; self = .binarization(value)
            case var .colorCorrection(value): value.isEnabled = newValue; self = .colorCorrection(value)
            case var .chromaticAberration(value): value.isEnabled = newValue; self = .chromaticAberration(value)
            case var .lensFlare(value): value.isEnabled = newValue; self = .lensFlare(value)
            case var .electricBeam(value): value.isEnabled = newValue; self = .electricBeam(value)
            case var .fireOutline(value): value.isEnabled = newValue; self = .fireOutline(value)
            case var .sobelChromatic(value): value.isEnabled = newValue; self = .sobelChromatic(value)
            case var .vignette(value): value.isEnabled = newValue; self = .vignette(value)
            case var .belowMask(value): value.isEnabled = newValue; self = .belowMask(value)
            }
        }
    }
}

extension ImageParameter {
    var effectKind: EffectKind? {
        switch self {
        case .particlesImageSize: return .particles
        case .particlesImageAngle: return .particles
        case .particlesImageSpread: return .particles
        case .particlesImageSpin: return .particles
        case .embersImageSize: return .embers
        case .embersImageAngle: return .embers
        case .embersImageSpread: return .embers
        case .embersImageSpin: return .embers
        case .snowImageSize: return .snow
        case .snowImageAngle: return .snow
        case .snowImageSpread: return .snow
        case .snowImageSpin: return .snow
        case .orbsImageSize: return .orbs
        case .orbsImageAngle: return .orbs
        case .orbsImageSpread: return .orbs
        case .orbsImageSpin: return .orbs
        case .shapeWidth, .shapeHeight, .shapeX, .shapeY, .shapeRotation, .shapeInnerRatio, .shapeOpacity: return .shape
        case .maskWidth, .maskHeight, .maskX, .maskY, .maskRotation, .maskInnerRatio, .maskFeather, .maskStrength: return .mask
        case .blurRadius: return .blur
        case .radialBlurStrength, .radialBlurSampleCount, .radialBlurX, .radialBlurY: return .radialBlur
        case .glareThreshold, .glareIntensity, .glareLength, .glareWidth, .glareAngle: return .crossGlare
        case .bloomThreshold, .bloomRadius, .bloomIntensity: return .bloom
        case .particlesCount, .particlesDiameter, .particlesSpeed, .particlesCurveStrength, .particlesOpacity, .emitter0X, .emitter0Y, .emitter1X, .emitter1Y, .emitter2X, .emitter2Y, .emitter3X, .emitter3Y: return .particles
        case .embersCount, .embersDiameter, .embersRiseSpeed, .embersWind, .embersSwaySpeed, .embersBrightness: return .embers
        case .snowCount, .snowDiameter, .snowFallSpeed, .snowWind, .snowOpacity: return .snow
        case .orbsCount, .orbsSaturation, .orbsSpeed, .orbsOpacity: return .orbs
        case .zoomLoopCenterX, .zoomLoopCenterY, .zoomLoopSpeed, .zoomLoopZoom, .zoomLoopBrightness, .zoomLoopOpacity: return .zoomLoop
        case .octSpeed, .octZoom, .octBrightness, .octOpacity: return .octgrams
        case .warpSpeed, .warpZoom, .warpBrightness, .warpOpacity: return .warpFlight
        case .radialSpeed, .radialZoom, .radialBrightness, .radialOpacity: return .radialFocus
        case .raysX, .raysY, .raysLength, .raysSquash, .raysCount, .raysThickness, .raysLengthVariation, .raysVariation, .raysFlicker, .raysIntensity, .raysGlow, .raysCoreSize, .raysCoreIntensity, .raysOpacity: return .radialRays
        case .straightAngle, .straightCount, .straightLength, .straightThickness, .straightSpeed, .straightLengthVariation, .straightThicknessVariation, .straightToneVariation, .straightFade, .straightGlow, .straightOpacity: return .straightLines
        case .sharpX, .sharpY, .sharpWidth, .sharpHeight, .sharpCount, .sharpThickness, .sharpLength, .sharpVariation, .sharpOpacity, .sharpTipLength, .sharpToneVariation: return .sharpFocus
        case .focusX, .focusY, .focusWidth, .focusHeight, .focusCount, .focusThickness, .focusLength, .focusVariation, .focusOpacity: return .focusLines
        case .shakeX, .shakeY, .shakeStrength: return .shake
        case .binarizationThreshold, .binarizationAmount: return .binarization
        case .colorHue, .colorBrightness, .colorSaturation: return .colorCorrection
        case .chromaticAmount, .chromaticAngle: return .chromaticAberration
        case .spiralX, .spiralY, .spiralRadius, .spiralCount, .spiralConvergenceTime, .spiralTurns, .spiralSpeed, .spiralDiameter, .spiralOpacity, .spiralImageSize, .spiralImageAngle, .spiralImageSpread, .spiralImageSpin: return .spiralParticles
        case .gradientX, .gradientY, .gradientPosition, .gradientWidth, .gradientAngle, .gradientBias, .gradientOpacity: return .gradientBackground
        case .beamX, .beamY, .beamAngle, .beamLength, .beamSpread, .beamCount, .beamWidth, .beamBend, .beamGlow, .beamBrightness, .beamSpeed: return .electricBeam
        case .fireX, .fireY, .fireWidth, .fireHeight, .fireSpread, .fireDetail, .fireSpeed, .fireBrightness, .fireOpacity, .fireHue: return .fireOutline
        case .sobelAmount, .sobelStrength, .sobelWidth, .sobelChromaticAmount, .sobelSpeed: return .sobelChromatic
        case .flareX, .flareY, .flareSize, .flareIntensity: return .lensFlare
        case .vignetteStrength, .vignetteSize, .vignetteSoftness: return .vignette
        case .belowMaskWidth, .belowMaskHeight, .belowMaskX, .belowMaskY, .belowMaskRotation, .belowMaskInnerRatio, .belowMaskFeather, .belowMaskStrength: return .belowMask
        default: return nil
        }
    }
}
