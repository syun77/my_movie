import Foundation

/// Parameter-independent interpolation shared by transform and Spine blend curves.
struct NumericCurve {
    var minimum: Double
    var maximum: Double
    var keys: [ImageKeyframe]
    var defaultValue = 0.0
    var valueRange: ClosedRange<Double>?
    var positive = false

    func value(at time: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return defaultValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        var lower = 0
        var upper = keys.count - 1
        while upper - lower > 1 {
            let mid = (lower + upper) / 2
            if keys[mid].time <= time { lower = mid } else { upper = mid }
        }
        let a = keys[lower]
        let b = keys[upper]
        if b.incomingInterpolation == .hold { return a.value }
        let t = (time - a.time) / (b.time - a.time)
        switch b.incomingInterpolation {
        case .pulse:
            return b.pulseIsHigh(at: t) ? b.value : a.value
        case .wave:
            let fraction = (1 - cos(2 * .pi * t / b.resolvedWavePeriod)) / 2
            return a.value * (1 - fraction) + b.value * fraction
        default: break
        }
        let fraction = b.incomingInterpolation == .smooth ? t * t * (3 - 2 * t) : t
        let linear = a.value * (1 - fraction) + b.value * fraction
        let value = linear + (a.midpointOffset ?? 0) * (4 * fraction * (1 - fraction))
        if let range = valueRange {
            return min(range.upperBound, max(range.lowerBound, value))
        }
        return positive ? max(Double.leastNonzeroMagnitude, value) : value
    }

    func plotSamples(from first: Double, through last: Double, steps: Int) -> [(time: Double, value: Double)] {
        let steps = max(1, steps)
        var times = Set([first, last])
        var jumps: [Double: (before: Double, after: Double)] = [:]
        for key in keys where first < key.time && key.time <= last { times.insert(key.time) }
        if keys.contains(where: {
            [.smooth, .wave].contains($0.incomingInterpolation) || ($0.midpointOffset ?? 0) != 0
        }) {
            for index in 0...steps { times.insert(first + (last - first) * Double(index) / Double(steps)) }
        }
        for (a, b) in zip(keys, keys.dropFirst()) where a.time <= last && b.time >= first {
            let length = b.time - a.time
            switch b.incomingInterpolation {
            case .hold: jumps[b.time] = (a.value, b.value)
            case .pulse:
                let transitions = b.pulseTransitions
                for transition in transitions {
                    jumps[a.time + length * transition.fraction] =
                        transition.isHigh ? (a.value, b.value) : (b.value, a.value)
                }
            case .wave:
                let phase = 2 * .pi / b.resolvedWavePeriod
                let fraction = (1 - cos(phase)) / 2
                jumps[b.time] = (a.value * (1 - fraction) + b.value * fraction, b.value)
                let sampleCount = max(1, Int(ceil(32 / b.resolvedWavePeriod)))
                for index in 0...sampleCount {
                    let time = a.time + length * Double(index) / Double(sampleCount)
                    if first < time && time < last { times.insert(time) }
                }
            default: break
            }
        }
        for time in jumps.keys where first <= time && time <= last { times.insert(time) }
        return times.sorted().flatMap { time -> [(Double, Double)] in
            if let jump = jumps[time] {
                return time > first ? [(time, jump.before), (time, jump.after)] : [(time, jump.after)]
            }
            return [(time, value(at: time))]
        }
    }

    func midpoint(after id: UUID) -> (time: Double, value: Double)? {
        guard let index = keys.firstIndex(where: { $0.id == id }), index + 1 < keys.count,
            keys[index + 1].incomingInterpolation != .hold
        else { return nil }
        let time = keys[index].time / 2 + keys[index + 1].time / 2
        let target = keys[index + 1]
        switch target.incomingInterpolation {
        case .pulse: return (time, minimum + target.pulseHandleFraction * (maximum - minimum))
        case .wave:
            let range = ImageKeyframe.wavePeriodRange
            let fraction = log(target.resolvedWavePeriod / range.lowerBound) / log(range.upperBound / range.lowerBound)
            return (time, minimum + fraction * (maximum - minimum))
        default: return (time, value(at: time))
        }
    }

    func midpointLabel(after id: UUID) -> String? {
        guard let index = keys.firstIndex(where: { $0.id == id }), index + 1 < keys.count else { return nil }
        let target = keys[index + 1]
        switch target.incomingInterpolation {
        case .pulse:
            let period = (target.time - keys[index].time) * target.resolvedPulsePeriod
            return String(format: "幅 %.3f秒  周期 %.3f秒", period / 2, period)
        case .wave: return String(format: "周期 %.3f秒", (target.time - keys[index].time) * target.resolvedWavePeriod)
        default: return nil
        }
    }

    mutating func adjustMidpoint(after id: UUID, handleValue: Double) {
        guard let index = keys.firstIndex(where: { $0.id == id }), index + 1 < keys.count else { return }
        let fraction = min(1, max(0, (handleValue - minimum) / (maximum - minimum)))
        switch keys[index + 1].incomingInterpolation {
        case .pulse:
            let range = ImageKeyframe.pulseCyclesRange
            let cycles = Int(pow(Double(range.upperBound), 1 - fraction).rounded())
            keys[index + 1].pulseCycles = min(range.upperBound, max(range.lowerBound, cycles))
            return
        case .wave:
            let range = ImageKeyframe.wavePeriodRange
            keys[index + 1].wavePeriod = range.lowerBound * pow(range.upperBound / range.lowerBound, fraction)
            return
        default: break
        }
        let linear = keys[index].value / 2 + keys[index + 1].value / 2
        let offset = handleValue - linear
        keys[index].midpointOffset = offset == 0 ? nil : offset
    }

    func key(near time: Double) -> ImageKeyframe? {
        keys.filter { abs($0.time - time) <= ImageCurve.timeTolerance }
            .min { abs($0.time - time) < abs($1.time - time) }
    }

    mutating func move(id: UUID, to time: Double, value: Double) throws {
        guard let index = keys.firstIndex(where: { $0.id == id }),
            index == 0 || time - keys[index - 1].time > ImageCurve.timeTolerance,
            index + 1 == keys.count || keys[index + 1].time - time > ImageCurve.timeTolerance
        else {
            throw StudioError.message("制御点は隣の点を越えたり重なったりできません。")
        }
        keys[index].time = time
        keys[index].value = value
    }
}
