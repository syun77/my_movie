import Foundation

struct ParameterAutomation: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case keys, lfo }
    struct KeyCurve: Codable, Equatable, Sendable { var keys: [ImageKeyframe] }
    var parameter: ImageParameter
    var mode: Mode = .keys
    var keyCurve: KeyCurve?
    var lfo: LFOSettings?
}

struct LFOSettings: Codable, Equatable, Sendable {
    enum Timebase: String, Codable, CaseIterable, Sendable { case hertz, beats }
    enum Origin: String, Codable, CaseIterable, Sendable { case song, clip }
    struct BeatPeriod: Codable, Equatable, Sendable {
        var numerator: Int
        var denominator: Int
        var value: Double { Double(numerator) / Double(denominator) }
        static let bases: [(String, Int, Int)] = [("16拍",16,1), ("8拍",8,1), ("全音符（4拍）",4,1), ("2分音符",2,1), ("4分音符",1,1), ("8分音符",1,2), ("16分音符",1,4), ("32分音符",1,8), ("64分音符",1,16)]
        static var choices: [(title: String, period: Self)] {
            bases.flatMap { title, n, d in
                [(title, Self(numerator: n, denominator: d)),
                 (title + "・付点", Self(numerator: n * 3, denominator: d * 2)),
                 (title + "・3連", Self(numerator: n * 2, denominator: d * 3))]
            }
        }
        var isValid: Bool { Self.choices.contains { $0.period == self } }
    }
    var timebase: Timebase = .beats
    var frequencyHz = 1.0
    var beatsPerCycle = BeatPeriod(numerator: 1, denominator: 1)
    var tilt = 0.0
    var curve = 0.0
    var amount = 0.0
    var bipolar = true
    var phaseDegrees = 0.0
    var phaseOrigin: Origin = .song
    var clockOffsetSeconds = 0.0

    func frequency(bpm: Double) -> Double {
        timebase == .hertz ? frequencyHz : 1 / BeatTiming.period(bpm: bpm, beatsPerCycle: beatsPerCycle.value)
    }
    func cycles(at time: Double, clipStart: Double, settings: SceneSettings) -> Double {
        let seconds = phaseOrigin == .song ? time - settings.beatOffset : time - clipStart + clockOffsetSeconds
        return seconds * frequency(bpm: settings.bpm) + phaseDegrees / 360
    }
    func isValid(for parameter: ImageParameter) -> Bool {
        [frequencyHz, tilt, curve, amount, phaseDegrees, clockOffsetSeconds].allSatisfy(\.isFinite)
            && (0.01...20).contains(frequencyHz) && beatsPerCycle.isValid
            && (-100...100).contains(tilt) && (-100...100).contains(curve)
            && (0...parameter.lfoAmountMaximum).contains(amount) && (0..<360).contains(phaseDegrees)
            && abs(clockOffsetSeconds) <= 1e12
    }
}

extension ImageParameter {
    var lfoAmountMaximum: Double {
        let range = valueRange ?? defaultRange
        return range.upperBound - range.lowerBound
    }
    var lfoAmountUnit: String { unit == "%" ? "%ポイント" : unit.isEmpty ? "個" : unit }
}

struct AutomationPlot {
    var samples: [(Double, Double)]
    var isEnvelope = false
}

enum LFOEvaluator {
    static func signal(phase: Double, settings: LFOSettings) -> Double {
        let p = phase - floor(phase)
        let apex = (settings.tilt / 100 + 1) / 2
        let rising = apex == 1 || (apex > 0 && p < apex)
        let u: Double
        if apex == 0 { u = 1 - p }
        else if apex == 1 { u = p }
        else { u = rising ? p / apex : (1 - p) / (1 - apex) }
        let c = settings.curve / 100
        let shaped: Double
        if c == -1 { shaped = u == 0.5 ? (rising ? 1 : 0) : (u < 0.5 ? 0 : 1) }
        else if c < 0 {
            if u <= 0 { shaped = 0 }
            else if u >= 1 { shaped = 1 }
            else {
                let logOdds = (log(u) - log1p(-u)) / (1 + c)
                shaped = logOdds >= 0 ? 1 / (1 + exp(-logOdds)) : exp(logOdds) / (1 + exp(logOdds))
            }
        } else { shaped = (1 - c) * u + c * (1 - cos(.pi * u)) / 2 }
        return settings.bipolar ? 2 * shaped - 1 : shaped
    }
    static func value(base: Double, at time: Double, clipStart: Double, settings: LFOSettings, scene: SceneSettings) -> Double {
        base + settings.amount * signal(phase: settings.cycles(at: time, clipStart: clipStart, settings: scene), settings: settings)
    }

    static func samples(from first: Double, through last: Double, pixels: Int, clipStart: Double,
                        settings: LFOSettings, scene: SceneSettings) -> [(Double, Double)] {
        plot(from: first, through: last, pixels: pixels, clipStart: clipStart, settings: settings, scene: scene).samples
    }

    /// Samples are bounded independently of project duration; jumps retain their two one-sided values.
    static func plot(from first: Double, through last: Double, pixels: Int, clipStart: Double,
                     settings: LFOSettings, scene: SceneSettings) -> AutomationPlot {
        guard last > first else { return AutomationPlot(samples: [(first, signal(phase: settings.cycles(at: first, clipStart: clipStart, settings: scene), settings: settings))]) }
        let frequency = settings.frequency(bpm: scene.bpm)
        let cycles = (last - first) * frequency
        let limit = 8192
        func envelope() -> AutomationPlot {
            AutomationPlot(samples: [(first, settings.bipolar ? -1 : 0), (first, 1), (last, settings.bipolar ? -1 : 0), (last, 1)], isEnvelope: true)
        }
        if cycles > Double(max(1, pixels)) / 2 || cycles * 32 > Double(limit / 2) { return envelope() }
        let count = min(limit / 2, max(2, max(pixels, Int(ceil(cycles * 32)))))
        var points = Set((0...count).map { first + (last - first) * Double($0) / Double(count) })
        let rawCycle = settings.cycles(at: first, clipStart: clipStart, settings: scene)
        let startCycle = rawCycle - floor(rawCycle)
        let endCycle = startCycle + cycles
        let a = (settings.tilt / 100 + 1) / 2
        let phases = [0.0, a / 2, a, (1 + a) / 2]
        for cycle in Int(floor(startCycle))...Int(ceil(endCycle)) {
            for phase in phases {
                let t = first + (Double(cycle) + phase - startCycle) / frequency
                if first <= t, t <= last { points.insert(t) }
            }
        }
        func value(_ time: Double) -> Double { signal(phase: settings.cycles(at: time, clipStart: clipStart, settings: scene), settings: settings) }
        var result: [(Double, Double)] = []
        func subdivide(_ t0: Double, _ v0: Double, _ t1: Double, _ v1: Double, depth: Int) {
            guard result.count < limit else { return }
            let mid = (t0 + t1) / 2, vm = value(mid)
            if depth < 12, t1 > t0, abs(vm - (v0 + v1) / 2) > 0.005 {
                subdivide(t0, v0, mid, vm, depth: depth + 1)
                subdivide(mid, vm, t1, v1, depth: depth + 1)
            } else { result.append((t1, v1)) }
        }
        let ordered = points.sorted()
        result.append((first, value(first)))
        for (t0, t1) in zip(ordered, ordered.dropFirst()) {
            let epsilon = min(1e-7 / frequency, (t1 - t0) / 1000)
            let before = value(t1 - epsilon), after = value(t1 + epsilon)
            if abs(before - after) > 0.1, settings.curve == -100 || abs(settings.tilt) == 100 {
                subdivide(t0, value(t0), t1 - epsilon, before, depth: 0)
                result.append((t1, before)); result.append((t1, after))
            } else { subdivide(t0, value(t0), t1, value(t1), depth: 0) }
        }
        return result.count >= limit ? envelope() : AutomationPlot(samples: result)
    }
}

extension VisualClip {
    func automation(_ parameter: ImageParameter) -> ParameterAutomation? { automations.first { $0.parameter == parameter } }
    func activeLFO(_ parameter: ImageParameter) -> LFOSettings? {
        guard let item = automation(parameter), item.mode == .lfo else { return nil }; return item.lfo
    }
    func hasAutomation(_ parameter: ImageParameter) -> Bool { automation(parameter) != nil }
    mutating func setAutomation(_ item: ParameterAutomation) {
        if let index = automations.firstIndex(where: { $0.parameter == item.parameter }) { automations[index] = item }
        else { automations.append(item) }
    }
    mutating func setAutomationMode(_ mode: ParameterAutomation.Mode, for parameter: ImageParameter) {
        guard mode == .lfo || hasAutomation(parameter) else { return }
        var item = automation(parameter) ?? ParameterAutomation(parameter: parameter)
        item.mode = mode
        if mode == .lfo, item.lfo == nil { item.lfo = LFOSettings() }
        setAutomation(item)
    }
    mutating func removeAutomation(_ parameter: ImageParameter) {
        automations.removeAll { $0.parameter == parameter }
        if audioModulations[parameter] == nil { automationRanges[parameter] = nil }
    }
}

/// Key editing uses ImageCurve as a transient view; persisted ranges have one owner.
enum AutomationCurves {
    static func curves(_ items: [ParameterAutomation], ranges: [ImageParameter: VisualClip.DisplayRange]) -> [ImageCurve] {
        items.compactMap { item in
            guard let keys = item.keyCurve?.keys, !keys.isEmpty else { return nil }
            var curve = ImageCurve(parameter: item.parameter); curve.keys = keys
            if let range = ranges[item.parameter] { curve.minimum = range.lower; curve.maximum = range.upper }
            return curve
        }
    }
    static func update(_ curves: [ImageCurve], items: inout [ParameterAutomation], ranges: inout [ImageParameter: VisualClip.DisplayRange]) {
        for index in items.indices { items[index].keyCurve = nil }
        for curve in curves where !curve.keys.isEmpty {
            let keyCurve = ParameterAutomation.KeyCurve(keys: curve.keys)
            if let index = items.firstIndex(where: { $0.parameter == curve.parameter }) { items[index].keyCurve = keyCurve }
            else { items.append(ParameterAutomation(parameter: curve.parameter, keyCurve: keyCurve)) }
            ranges[curve.parameter] = .init(lower: curve.minimum, upper: curve.maximum)
        }
        items.removeAll { $0.keyCurve == nil && $0.lfo == nil }
    }
}
