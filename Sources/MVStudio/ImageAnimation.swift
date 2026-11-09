import Foundation

enum ImageParameter: String, CaseIterable, Codable, Sendable {
    case x, y, scale, rotation

    var title: String {
        switch self {
        case .x: return "位置 X"
        case .y: return "位置 Y"
        case .scale: return "拡大縮小"
        case .rotation: return "回転"
        }
    }

    var unit: String {
        switch self {
        case .x, .y: return "px"
        case .scale: return "%"
        case .rotation: return "°"
        }
    }

    var defaultValue: Double { self == .scale ? 100 : 0 }

    var defaultRange: ClosedRange<Double> {
        switch self {
        case .x: return -960...960
        case .y: return -540...540
        case .scale: return 10...200
        case .rotation: return -180...180
        }
    }

    func accepts(_ value: Double) -> Bool {
        value.isFinite && (self != .scale || value > 0)
    }
}

enum AutomaticAnimation: String, CaseIterable, Codable, Sendable {
    case off, transient, beat

    var title: String {
        switch self {
        case .off: return "オフ"
        case .transient: return "トランジェント"
        case .beat: return "拍"
        }
    }

    func pulse(at time: Double, settings: SceneSettings, transientPulse: Double) -> Double {
        switch self {
        case .off: return 0
        case .transient: return transientPulse
        case .beat:
            let elapsed = time - settings.beatOffset
            guard elapsed >= 0 else { return 0 }
            let period = 60 / settings.bpm
            let phase = elapsed.truncatingRemainder(dividingBy: period)
            return zoomPulse(elapsed: period - phase < 1e-9 ? 0 : phase)
        }
    }
}

func zoomPulse(elapsed: Double) -> Double {
    let remaining = max(0, 1 - elapsed / 0.3)
    return remaining * remaining * remaining
}

struct ImageKeyframe: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var time: Double
    var value: Double
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

    func value(at time: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return parameter.defaultValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        var lower = 0
        var upper = keys.count - 1
        while upper - lower > 1 {
            let mid = (lower + upper) / 2
            if keys[mid].time <= time { lower = mid } else { upper = mid }
        }
        let a = keys[lower], b = keys[upper]
        let fraction = (time - a.time) / (b.time - a.time)
        return a.value * (1 - fraction) + b.value * fraction
    }

    func key(near time: Double) -> ImageKeyframe? {
        keys.filter { abs($0.time - time) <= Self.timeTolerance }
            .min { abs($0.time - time) < abs($1.time - time) }
    }

    func validate(ids: inout Set<UUID>) throws {
        guard parameter.accepts(minimum), parameter.accepts(maximum), minimum < maximum,
              (maximum - minimum).isFinite, !keys.isEmpty else {
            throw StudioError.message("グラフの最小値は最大値より小さくしてください。拡大率は正の数値が必要です。")
        }
        var previous: Double?
        for key in keys {
            guard key.time.isFinite, parameter.accepts(key.value), ids.insert(key.id).inserted,
                  previous.map({ key.time - $0 > Self.timeTolerance && (key.time - $0).isFinite }) ?? true else {
                throw StudioError.message("制御点の時刻または値が不正です。")
            }
            previous = key.time
        }
    }

    mutating func move(id: UUID, to time: Double, value: Double) throws {
        guard let index = keys.firstIndex(where: { $0.id == id }),
              index == 0 || time - keys[index - 1].time > Self.timeTolerance,
              index + 1 == keys.count || keys[index + 1].time - time > Self.timeTolerance else {
            throw StudioError.message("制御点は隣の点を越えたり重なったりできません。")
        }
        keys[index].time = time
        keys[index].value = value
    }
}

extension ImageClip {
    func curve(_ parameter: ImageParameter) -> ImageCurve? {
        curves.first { $0.parameter == parameter }
    }

    func manualValue(_ parameter: ImageParameter, at time: Double) -> Double {
        curve(parameter)?.value(at: time - start) ?? baseValue(parameter)
    }

    func baseValue(_ parameter: ImageParameter) -> Double {
        fixedValues[parameter] ?? parameter.defaultValue
    }

    mutating func setBaseValue(_ value: Double, for parameter: ImageParameter, resetting: Bool = false) {
        let difference = value - baseValue(parameter)
        if difference != 0, var curve = curve(parameter) {
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
            setCurve(curve)
        }
        fixedValues[parameter] = value == parameter.defaultValue ? nil : value
    }

    func scale(at time: Double, settings: SceneSettings, transientPulse: Double) -> Double {
        let pulse = automaticAnimation.pulse(at: time, settings: settings, transientPulse: transientPulse)
        return (manualValue(.scale, at: time) / 100) * (1 + pulseAmount * pulse)
    }

    mutating func trimStart(to time: Double) {
        let delta = time - start
        for index in curves.indices {
            for keyIndex in curves[index].keys.indices { curves[index].keys[keyIndex].time -= delta }
        }
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
        var curve = curve(parameter) ?? ImageCurve(parameter: parameter)
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
        if let index = curves.firstIndex(where: { $0.parameter == curve.parameter }) { curves[index] = curve }
        else { curves.append(curve) }
    }

    mutating func removeKey(_ id: UUID, parameter: ImageParameter) {
        guard let index = curves.firstIndex(where: { $0.parameter == parameter }),
              let key = curves[index].keys.firstIndex(where: { $0.id == id }) else { return }
        let value = curves[index].keys.remove(at: key).value
        if curves[index].keys.isEmpty {
            curves.remove(at: index)
            fixedValues[parameter] = value
        }
    }

    func validateAnimation(ids: inout Set<UUID>) throws {
        guard pulseAmount.isFinite, (0...0.25).contains(pulseAmount),
              fixedValues.allSatisfy({ $0.key.accepts($0.value) }),
              Set(curves.map(\.parameter)).count == curves.count else {
            throw StudioError.message("画像の変形または自動アニメの設定が不正です。")
        }
        for curve in curves { try curve.validate(ids: &ids) }
    }
}
