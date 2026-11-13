import Foundation

struct SpineAnimationKey: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var time: Double
    var animationName: String
}

struct SpineBlend: Codable, Equatable, Sendable {
    var minimumAnimation: String
    var maximumAnimation: String
    var baseWeight = 0.0
    var keys: [ImageKeyframe] = []
    var automated = true
    var curve: NumericCurve {
        NumericCurve(minimum: 0, maximum: 1, keys: keys, defaultValue: baseWeight, valueRange: 0...1)
    }
    func weight(at time: Double) -> Double {
        guard automated, let first = keys.first, time >= first.time else { return baseWeight }
        return min(1, max(0, curve.value(at: time)))
    }
    func samples(from first: Double, through last: Double, steps: Int) -> [(time: Double, value: Double)] {
        guard automated, let key = keys.first else { return [(first, baseWeight), (last, baseWeight)] }
        let start = max(first, key.time)
        var result: [(Double, Double)] = []
        if first < key.time {
            result.append((first, baseWeight))
            if key.time > last { return result + [(last, baseWeight)] }
            result.append((key.time, baseWeight))
        }
        result += curve.plotSamples(from: start, through: last, steps: steps).map {
            ($0.time, min(1, max(0, $0.value)))
        }
        return result
    }
}

enum SpineAnimationMode: Codable, Equatable, Sendable {
    case single(String)
    case selection(base: String, keys: [SpineAnimationKey])
    case blend(SpineBlend)
}

struct SpinePoseRequest: Equatable, Sendable {
    let animation: String
    var secondAnimation: String?
    var weight = 0.0
}

struct SpinePlayback: Codable, Sendable, Equatable {
    var mode: SpineAnimationMode
    var sourceIn: Double = 0
    var loop = true
    init(animationName: String, sourceIn: Double = 0, loop: Bool = true) {
        mode = .single(animationName)
        self.sourceIn = sourceIn
        self.loop = loop
    }
    var animationName: String {
        get {
            switch mode {
            case .single(let name), .selection(let name, _): return name
            case .blend(let value): return value.minimumAnimation
            }
        }
        set {
            switch mode {
            case .single: mode = .single(newValue)
            case .selection(_, let keys): mode = .selection(base: newValue, keys: keys)
            case .blend(var value):
                value.minimumAnimation = newValue
                mode = .blend(value)
            }
        }
    }
    var hasLane: Bool {
        switch mode {
        case .single: return false
        case .selection: return true
        case .blend(let value): return value.automated
        }
    }
    var names: Set<String> {
        switch mode {
        case .single(let name): return [name]
        case .selection(let base, let keys): return Set([base] + keys.map(\.animationName))
        case .blend(let value): return [value.minimumAnimation, value.maximumAnimation]
        }
    }
    var keyIDs: [UUID] {
        switch mode {
        case .single: return []
        case .selection(_, let keys): return keys.map(\.id)
        case .blend(let value): return value.keys.map(\.id)
        }
    }
    var isValid: Bool { (try? validate()) != nil }
    func validate() throws {
        guard sourceIn.isFinite, (0...1e12).contains(sourceIn), names.allSatisfy({ !$0.isEmpty }),
            Set(keyIDs).count == keyIDs.count
        else { throw StudioError.message("Spineの再生指定が不正です。") }
        var times: [Double] = []
        switch mode {
        case .single: break
        case .selection(_, let keys): times = keys.map(\.time)
        case .blend(let value):
            guard value.minimumAnimation != value.maximumAnimation, value.baseWeight.isFinite,
                (0...1).contains(value.baseWeight), value.automated || value.keys.isEmpty
            else { throw StudioError.message("ブレンドには異なる2つのアニメーションと0〜100%の値が必要です。") }
            times = value.keys.map(\.time)
            for key in value.keys {
                guard key.value.isFinite, (0...1).contains(key.value),
                    ImageKeyframe.pulseCyclesRange.contains(key.resolvedPulseCycles),
                    ImageKeyframe.wavePeriodRange.contains(key.resolvedWavePeriod),
                    key.midpointOffset.map({ $0.isFinite && abs($0) <= Double.greatestFiniteMagnitude / 16 }) ?? true
                else { throw StudioError.message("ブレンドの制御点が不正です。") }
            }
        }
        guard times.allSatisfy(\.isFinite),
            zip(times, times.dropFirst()).allSatisfy({ $1 - $0 > ImageCurve.timeTolerance && ($1 - $0).isFinite })
        else { throw StudioError.message("アニメーション制御点の時刻が不正です。") }
    }
    func resolved(at time: Double) -> SpinePoseRequest {
        switch mode {
        case .single(let name): return SpinePoseRequest(animation: name)
        case .selection(let base, let keys):
            return SpinePoseRequest(animation: keys.last(where: { $0.time <= time })?.animationName ?? base)
        case .blend(let value):
            return SpinePoseRequest(
                animation: value.minimumAnimation, secondAnimation: value.maximumAnimation,
                weight: value.weight(at: time))
        }
    }
    mutating func trim(by delta: Double) {
        switch mode {
        case .single: break
        case .selection(let base, let keys):
            mode = .selection(
                base: base,
                keys: keys.map {
                    var key = $0
                    key.time -= delta
                    return key
                })
        case .blend(var value):
            for i in value.keys.indices { value.keys[i].time -= delta }
            mode = .blend(value)
        }
    }
    mutating func renewKeyIDs() {
        switch mode {
        case .single: break
        case .selection(let base, let keys):
            mode = .selection(
                base: base,
                keys: keys.map {
                    var key = $0
                    key.id = UUID()
                    return key
                })
        case .blend(var value):
            for i in value.keys.indices { value.keys[i].id = UUID() }
            mode = .blend(value)
        }
    }
    mutating func createSelection() { mode = .selection(base: animationName, keys: []) }
    mutating func createBlend(minimum: String, maximum: String, discardingKeys: Bool = false) throws {
        guard minimum != maximum else { throw StudioError.message("異なる2つのアニメーションを選んでください。") }
        var blend = SpineBlend(minimumAnimation: minimum, maximumAnimation: maximum)
        switch mode {
        case .selection(let base, let keys) where !discardingKeys:
            guard names.isSubset(of: [minimum, maximum]) else {
                throw StudioError.message("既存キーに別のアニメーションがあります。キーを削除して切り替える操作を選んでください。")
            }
            blend.baseWeight = base == maximum ? 1 : 0
            blend.keys = keys.map {
                ImageKeyframe(
                    id: $0.id, time: $0.time, value: $0.animationName == maximum ? 1 : 0, interpolation: .hold)
            }
        case .blend(var value):
            value.minimumAnimation = minimum
            value.maximumAnimation = maximum
            value.automated = true
            blend = value
        default: break
        }
        mode = .blend(blend)
    }
    mutating func removeLane(at time: Double) {
        switch mode {
        case .single: break
        case .selection: mode = .single(resolved(at: time).animation)
        case .blend(var value):
            value.baseWeight = value.weight(at: time)
            value.keys = []
            value.automated = false
            mode = .blend(value)
        }
    }
}
