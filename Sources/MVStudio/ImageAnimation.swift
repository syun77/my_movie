import Foundation

enum ImageParameter: String, CaseIterable, Codable, Sendable {
    case x, y, scale, rotation, opacity
    case blurRadius, bloomThreshold, bloomRadius, bloomIntensity
    case particlesCount, particlesDiameter, particlesSpeed, particlesCurveStrength, particlesOpacity
    case embersCount, embersDiameter, embersRiseSpeed, embersWind, embersSwaySpeed, embersBrightness
    case snowCount, snowDiameter, snowFallSpeed, snowWind, snowOpacity
    case colorHue, colorBrightness, colorSaturation
    case shakeX, shakeY, shakeStrength
    case orbsCount, orbsSaturation, orbsSpeed, orbsOpacity
    case emitter0X, emitter0Y, emitter1X, emitter1Y, emitter2X, emitter2Y, emitter3X, emitter3Y

    var title: String {
        if let effect = effect { return effect.title }
        switch self {
        case .x: return "位置 X"
        case .y: return "位置 Y"
        case .scale: return "拡大縮小"
        case .rotation: return "回転"
        case .opacity: return "不透明度"
        default: return ""
        }
    }

    var unit: String {
        if let effect { return effect.unit }
        switch self {
        case .x, .y: return "px"
        case .scale, .opacity: return "%"
        case .rotation: return "°"
        default: return ""
        }
    }

    var defaultValue: Double { effect?.initial ?? ([.scale, .opacity].contains(self) ? 100 : 0) }

    var defaultRange: ClosedRange<Double> {
        if let effect { return effect.range }
        switch self {
        case .x: return -960...960
        case .y: return -540...540
        case .scale: return 10...200
        case .rotation: return -180...180
        case .opacity: return 0...100
        default: return 0...100
        }
    }

    var valueRange: ClosedRange<Double>? { self == .opacity ? 0...100 : effect?.range }

    func accepts(_ value: Double) -> Bool {
        value.isFinite && (valueRange.map { $0.contains(value) } ?? (self != .scale || value > 0))
    }
}

enum ImageInterpolation: String, CaseIterable, Codable, Sendable {
    case single, smooth, hold, pulse, wave

    var title: String {
        switch self {
        case .single: return "シングル曲線"
        case .smooth: return "スムーズ"
        case .hold: return "ホールド"
        case .pulse: return "パルス"
        case .wave: return "ウェーブ"
        }
    }
}

struct ImageKeyframe: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var time: Double
    var value: Double
    var midpointOffset: Double?
    var interpolation: ImageInterpolation?
    var pulseCycles: Int?
    var wavePeriod: Double?

    static let pulseCyclesRange = 1...20
    static let wavePeriodRange = 0.05...2.0
    var resolvedPulseCycles: Int { pulseCycles ?? 4 }
    var resolvedWavePeriod: Double { wavePeriod ?? 1 }

    var resolvedPulsePeriod: Double { 1 / Double(resolvedPulseCycles) }

    var pulseHandleFraction: Double {
        1 - log(Double(resolvedPulseCycles)) / log(Double(Self.pulseCyclesRange.upperBound))
    }

    func pulseIsHigh(at fraction: Double) -> Bool {
        Int(floor(fraction * Double(resolvedPulseCycles * 2))) % 2 == 1
    }

    var pulseTransitions: [(fraction: Double, isHigh: Bool)] {
        let halves = resolvedPulseCycles * 2
        return (1..<halves).map { (Double($0) / Double(halves), $0 % 2 == 1) }
    }

    var incomingInterpolation: ImageInterpolation { interpolation ?? .single }
}

struct ImageCurve: Codable, Equatable, Sendable {
    static let timeTolerance = 1e-6

    let parameter: ImageParameter
    var minimum: Double
    var maximum: Double
    var keys: [ImageKeyframe] = []

    init(parameter: ImageParameter) {
        self.parameter = parameter
        minimum = parameter.defaultRange.lowerBound
        maximum = parameter.defaultRange.upperBound
    }

    var numeric: NumericCurve {
        NumericCurve(minimum: minimum, maximum: maximum, keys: keys, defaultValue: parameter.defaultValue,
                     valueRange: parameter.valueRange, positive: parameter == .scale)
    }
    func value(at time: Double) -> Double { numeric.value(at: time) }
    func plotSamples(from first: Double, through last: Double, steps: Int) -> [(time: Double, value: Double)] { numeric.plotSamples(from: first, through: last, steps: steps) }
    func midpoint(after id: UUID) -> (time: Double, value: Double)? { numeric.midpoint(after: id) }
    func midpointLabel(after id: UUID) -> String? { numeric.midpointLabel(after: id) }
    func key(near time: Double) -> ImageKeyframe? { numeric.key(near: time) }
    mutating func adjustMidpoint(after id: UUID, handleValue: Double) {
        var curve = numeric; curve.adjustMidpoint(after: id, handleValue: handleValue); keys = curve.keys
    }

    func validate(ids: inout Set<UUID>) throws {
        guard parameter.accepts(minimum), parameter.accepts(maximum), minimum < maximum,
              (maximum - minimum).isFinite, !keys.isEmpty else {
            throw StudioError.message("グラフの最小値は最大値より小さくしてください。拡大率は正の数値が必要です。")
        }
        var previous: Double?
        for key in keys {
            guard key.time.isFinite, parameter.accepts(key.value),
                  ImageKeyframe.pulseCyclesRange.contains(key.resolvedPulseCycles),
                  ImageKeyframe.wavePeriodRange.contains(key.resolvedWavePeriod),
                  key.midpointOffset.map({ $0.isFinite && abs($0) <= Double.greatestFiniteMagnitude / 16 }) ?? true,
                  ids.insert(key.id).inserted,
                  previous.map({ key.time - $0 > Self.timeTolerance && (key.time - $0).isFinite }) ?? true else {
                throw StudioError.message("制御点の時刻または値が不正です。")
            }
            previous = key.time
        }
    }

    mutating func move(id: UUID, to time: Double, value: Double) throws {
        var curve = numeric; try curve.move(id: id, to: time, value: value); keys = curve.keys
    }

}

extension VisualClip {
    func curve(_ parameter: ImageParameter) -> ImageCurve? {
        curves.first { $0.parameter == parameter }
    }

    func manualValue(_ parameter: ImageParameter, at time: Double) -> Double {
        curve(parameter).flatMap { $0.keys.isEmpty ? nil : $0.value(at: time - start) } ?? baseValue(parameter)
    }

    func baseValue(_ parameter: ImageParameter) -> Double {
        parameter.effect.flatMap { $0.read(effects ?? ImageEffects()) } ?? fixedValues[parameter] ?? parameter.defaultValue
    }

    mutating func setBaseValue(_ value: Double, for parameter: ImageParameter, resetting: Bool = false) {
        let value = parameter.effect != nil && parameter.rawValue.hasSuffix("Count") ? value.rounded() : value
        let difference = value - baseValue(parameter)
        if difference != 0, var curve = displayCurve(parameter) {
            curve.minimum += difference
            curve.maximum += difference
            for index in curve.keys.indices { curve.keys[index].value += difference }
            if resetting, parameter == .scale {
                if curve.minimum <= 0 { curve.minimum = parameter.defaultRange.lowerBound }
                if curve.maximum <= curve.minimum { curve.maximum = parameter.defaultRange.upperBound }
                for index in curve.keys.indices where curve.keys[index].value <= 0 {
                    curve.keys[index].value = 0.1
                }
            }
            if let range = parameter.valueRange {
                curve.minimum = max(range.lowerBound, curve.minimum)
                curve.maximum = min(range.upperBound, curve.maximum)
                if curve.minimum >= curve.maximum {
                    curve.minimum = range.lowerBound
                    curve.maximum = range.upperBound
                }
                for index in curve.keys.indices {
                    curve.keys[index].value = min(range.upperBound, max(range.lowerBound, curve.keys[index].value))
                }
            }
            setDisplayCurve(curve)
        }
        if let effect = parameter.effect {
            if let current = effects { effects = effect.write(current, value) }
        } else {
            fixedValues[parameter] = value == parameter.defaultValue ? nil : value
        }
    }

    mutating func trimStart(to time: Double) {
        let delta = time - start
        if let sourceIn = content.sourceIn { content.setSourceIn(max(0, sourceIn + delta * content.speed)) }
        if var playback = content.spinePlayback { playback.trim(by: delta); content = .spine(playback) }
        for index in curves.indices {
            for keyIndex in curves[index].keys.indices { curves[index].keys[keyIndex].time -= delta }
        }
        effects?.particles?.phaseOffset += delta
        effects?.embers?.phaseOffset += delta
        effects?.snow?.phaseOffset += delta
        effects?.orbs?.phaseOffset += delta
        effects?.shake?.phaseOffset += delta
        start = time
    }

    func containsKey(_ key: ImageKeyframe) -> Bool {
        let tolerance = ImageCurve.timeTolerance
        return key.time >= -tolerance && key.time <= end - start + tolerance
    }

    func keyTime(at time: Double, grid: TimelineSnapGrid?) -> Double {
        let bounded = min(end, max(start, time))
        guard let grid else { return bounded }
        let nearest = grid.nearest(bounded)
        var candidates = [start, end]
        if (start...end).contains(nearest) { candidates.append(nearest) }
        return candidates.min { abs($0 - bounded) < abs($1 - bounded) } ?? bounded
    }

    mutating func setKey(_ parameter: ImageParameter, at time: Double, value: Double) -> UUID {
        var curve = displayCurve(parameter) ?? ImageCurve(parameter: parameter)
        let local = time - start
        let id: UUID
        if let key = curve.key(near: local), let index = curve.keys.firstIndex(where: { $0.id == key.id }) {
            id = key.id
            curve.keys[index].value = value
        } else {
            let key = ImageKeyframe(time: local, value: value)
            id = key.id
            curve.keys.append(key)
            curve.keys.sort { $0.time < $1.time }
        }
        setCurve(curve)
        return id
    }

    mutating func setCurve(_ curve: ImageCurve) {
        automationRanges[curve.parameter] = nil
        if let index = curves.firstIndex(where: { $0.parameter == curve.parameter }) { curves[index] = curve }
        else { curves.append(curve) }
    }

    mutating func removeKey(_ id: UUID, parameter: ImageParameter) {
        guard let index = curves.firstIndex(where: { $0.parameter == parameter }),
              let key = curves[index].keys.firstIndex(where: { $0.id == id }) else { return }
        let value = curves[index].keys.remove(at: key).value
        if curves[index].keys.isEmpty {
            let removed = curves.remove(at: index)
            if audioModulations[parameter] != nil { automationRanges[parameter] = DisplayRange(lower: removed.minimum, upper: removed.maximum) }
            setBaseValue(value, for: parameter)
        }
    }

    func validateAnimation(ids: inout Set<UUID>) throws {
        guard audioModulations.allSatisfy({ $0.value.isValid(for: $0.key) && ($0.key.effect == nil || $0.key.effect?.read(effects ?? ImageEffects()) != nil) }),
              automationRanges.allSatisfy({ $0.key.accepts($0.value.lower) && $0.key.accepts($0.value.upper) && $0.value.lower < $0.value.upper && audioModulations[$0.key] != nil && curve($0.key) == nil }),
              fixedValues.allSatisfy({ $0.key.accepts($0.value) }),
              Set(curves.map(\.parameter)).count == curves.count else {
            throw StudioError.message("画像の変形または自動アニメの設定が不正です。")
        }
        for curve in curves { try curve.validate(ids: &ids) }
    }
}
