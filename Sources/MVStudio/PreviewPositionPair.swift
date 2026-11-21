import Foundation

struct PreviewPositionPair {
    let x: ImageParameter
    let y: ImageParameter
    let title: String
    var coordinates = PreviewHandleCoordinates()
    let enabled: (ImageEffects) -> Bool

    static let all: [Self] = [
        Self(x: .x, y: .y, title: "素材の位置", coordinates: PreviewHandleCoordinates(centered: true), enabled: { _ in true }),
        Self(x: .spiralX, y: .spiralY, title: "渦巻き粒子 中心", enabled: { $0.spiralParticles?.isEnabled == true }),
        Self(x: .gradientX, y: .gradientY, title: "グラデーション背景 中心", enabled: { $0.gradientBackground?.isEnabled == true }),
        Self(x: .beamX, y: .beamY, title: "電撃ビーム 中心", enabled: { $0.electricBeam?.isEnabled == true }),
        Self(x: .fireX, y: .fireY, title: "炎アウトライン 中心", enabled: { $0.fireOutline?.isEnabled == true }),
        Self(x: .flareX, y: .flareY, title: "レンズフレア 光源", enabled: { $0.lensFlare?.isEnabled == true }),
        Self(x: .radialBlurX, y: .radialBlurY, title: "放射ブラー 中心", enabled: { $0.radialBlur?.isEnabled == true }),
        Self(x: .zoomLoopCenterX, y: .zoomLoopCenterY, title: "拡大ループ 中心", enabled: { $0.zoomLoop?.isEnabled == true }),
        Self(x: .focusX, y: .focusY, title: "集中線 中心", enabled: { $0.focusLines?.isEnabled == true }),
        Self(x: .sharpX, y: .sharpY, title: "集中線３ 中心", enabled: { $0.sharpFocus?.isEnabled == true }),
        Self(x: .raysX, y: .raysY, title: "放射光線 中心", enabled: { $0.radialRays?.isEnabled == true }),
        Self(x: .shapeX, y: .shapeY, title: "図形 中心", enabled: { $0.shape?.isEnabled == true }),
        Self(x: .belowMaskX, y: .belowMaskY, title: "直下段マスク 中心", enabled: { $0.belowMask?.isEnabled == true }),
        Self(x: .maskX, y: .maskY, title: "マスク 中心", enabled: { $0.mask?.isEnabled == true }),
        Self(x: .emitter0X, y: .emitter0Y, title: "光の粒子 発生源1", enabled: { $0.particles?.isEnabled == true && ($0.particles?.emitters.count ?? 0) > 0 }),
        Self(x: .emitter1X, y: .emitter1Y, title: "光の粒子 発生源2", enabled: { $0.particles?.isEnabled == true && ($0.particles?.emitters.count ?? 0) > 1 }),
        Self(x: .emitter2X, y: .emitter2Y, title: "光の粒子 発生源3", enabled: { $0.particles?.isEnabled == true && ($0.particles?.emitters.count ?? 0) > 2 }),
        Self(x: .emitter3X, y: .emitter3Y, title: "光の粒子 発生源4", enabled: { $0.particles?.isEnabled == true && ($0.particles?.emitters.count ?? 0) > 3 })
    ]
    static func containing(_ parameter: ImageParameter) -> Self? { all.first { $0.x == parameter || $0.y == parameter } }
    func position(in clip: VisualClip) -> CGPoint { CGPoint(x: clip.baseValue(x), y: clip.baseValue(y)) }
    func evaluatedPosition(in clip: VisualClip, at time: Double, settings: SceneSettings, features: AudioFeatures?) -> CGPoint {
        var point = CGPoint(x: ParameterEvaluator.value(x, clip: clip, at: time, settings: settings, features: features),
                            y: ParameterEvaluator.value(y, clip: clip, at: time, settings: settings, features: features))
        if x == .x, let shake = clip.evaluatedEffects(at: time, settings: settings, features: features)?.shake {
            let offset = shake.displacement(at: time - clip.start)
            point.x += offset.x; point.y += offset.y
        }
        if x == .flareX, let flare = clip.evaluatedEffects(at: time, settings: settings, features: features)?.lensFlare {
            let source = flare.sourcePosition(at: time - clip.start)
            point = CGPoint(x: source.x * 1920, y: source.y * 1080)
        }
        return point
    }

    func moving(_ original: VisualClip, to point: CGPoint) -> VisualClip {
        var clip = original
        for (parameter, value) in [(x, point.x), (y, point.y)] {
            guard value.isFinite else { continue }
            let base = original.baseValue(parameter)
            let rounded = base + (value - base).rounded()
            let normalized = parameter.valueRange.map { min($0.upperBound, max($0.lowerBound, rounded)) } ?? rounded
            clip.setBaseValue(normalized, for: parameter)
        }
        return clip
    }
}
