import Foundation

struct TransientBand: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case all, low, mid, high, custom
        var title: String {
            switch self {
            case .all: return "全帯域"
            case .low: return "低域（180Hz未満）"
            case .mid: return "中域（180〜2400Hz）"
            case .high: return "高域（2400Hz以上）"
            case .custom: return "カスタム"
            }
        }
    }
    var kind: Kind = .all
    var lowerHz = 40.0
    var upperHz = 180.0
    var key: Self { kind == .custom ? self : Self(kind: kind) }
    var isValid: Bool {
        lowerHz.isFinite && upperHz.isFinite && lowerHz.rounded() == lowerHz && upperHz.rounded() == upperHz
            && lowerHz >= 20 && upperHz <= 20000 && lowerHz < upperHz
    }
    func bounds(sampleRate: Double) -> ClosedRange<Double>? {
        let top = min(20000, sampleRate * 0.499)
        let lower: Double, upper: Double
        switch kind {
        case .all: lower = 20; upper = top
        case .low: lower = 20; upper = min(180, top)
        case .mid: lower = 180; upper = min(2400, top)
        case .high: lower = 2400; upper = top
        case .custom: lower = lowerHz; upper = min(upperHz, top)
        }
        return lower < upper ? lower...upper : nil
    }
}

struct AudioModulation: Codable, Equatable, Sendable {
    enum Source: String, Codable, CaseIterable, Sendable {
        case beat, transient
        var title: String { self == .beat ? "拍" : "トランジェント" }
    }
    enum Blend: String, Codable, CaseIterable, Sendable {
        case add, relative
        var title: String { self == .add ? "加算" : "相対変化" }
    }
    var enabled = true
    var source: Source = .transient
    var blend: Blend = .add
    var amount = 0.0
    var releaseSeconds = 0.3
    var beatNoteDenominator = 4
    var transientBand = TransientBand()

    static func initial(for parameter: ImageParameter) -> Self {
        Self(blend: parameter == .scale ? .relative : .add, amount: parameter == .scale ? 8 : parameter == .opacity ? -40 : 20)
    }
    func isValid(for parameter: ImageParameter) -> Bool {
        amount.isFinite && parameter.modulationRange(blend).contains(amount)
            && (blend != .relative || parameter.allowsRelativeModulation)
            && releaseSeconds.isFinite && (0.03...2).contains(releaseSeconds)
            && (1...16).contains(beatNoteDenominator) && transientBand.isValid
    }
    func events(from first: Double, through last: Double, settings: SceneSettings, features: AudioFeatures?) -> [Double] {
        guard enabled else { return [] }
        if source == .beat { return BeatTiming.events(from: first, through: last, settings: settings, denominator: beatNoteDenominator) }
        return features?.transientEvents(for: transientBand, from: first, through: last) ?? []
    }
    func signal(at time: Double, settings: SceneSettings, features: AudioFeatures?) -> Double {
        guard enabled else { return 0 }
        let event: Double?
        if source == .beat {
            event = BeatTiming.latest(at: time, settings: settings, denominator: beatNoteDenominator)
        } else {
            event = features?.latestTransient(at: time, band: transientBand)
        }
        guard let event else { return 0 }
        let remaining = max(0, 1 - max(0, time - event) / releaseSeconds)
        return remaining * remaining * remaining
    }
}

enum BeatTiming {
    static func period(bpm: Double, denominator: Int) -> Double { 240 / bpm / Double(denominator) }
    static func latest(at time: Double, settings: SceneSettings, denominator: Int) -> Double? {
        guard time.isFinite, time >= settings.beatOffset, settings.bpm.isFinite, settings.bpm > 0, (1...16).contains(denominator) else { return nil }
        let interval = period(bpm: settings.bpm, denominator: denominator)
        let position = (time - settings.beatOffset) / interval
        let tolerance = max(1, abs(position)) * Double.ulpOfOne * 8
        return settings.beatOffset + floor(position + tolerance) * interval
    }
    static func events(from first: Double, through last: Double, settings: SceneSettings, denominator: Int) -> [Double] {
        guard first.isFinite, last.isFinite, last >= first, last >= settings.beatOffset, settings.bpm > 0, (1...16).contains(denominator) else { return [] }
        let interval = period(bpm: settings.bpm, denominator: denominator)
        let firstIndex = max(0, Int(ceil((first - settings.beatOffset) / interval)))
        let lastIndex = Int(floor((last - settings.beatOffset) / interval))
        guard firstIndex <= lastIndex else { return [] }
        return (firstIndex...lastIndex).map { settings.beatOffset + Double($0) * interval }
    }
}

extension ImageParameter {
    var allowsRelativeModulation: Bool { self == .scale || valueRange.map { $0.lowerBound >= 0 } == true }
    func modulationRange(_ blend: AudioModulation.Blend) -> ClosedRange<Double> {
        if blend == .relative { return -100...1000 }
        let span = defaultRange.upperBound - defaultRange.lowerBound
        return -max(100, span * 2)...max(100, span * 2)
    }
}

enum ParameterEvaluator {
    static func value(_ parameter: ImageParameter, clip: VisualClip, at time: Double,
                      settings: SceneSettings, features: AudioFeatures?) -> Double {
        combine(clip.manualValue(parameter, at: time), parameter: parameter, modulation: clip.audioModulations[parameter],
                at: time, settings: settings, features: features)
    }

    private static func combine(_ base: Double, parameter: ImageParameter, modulation: AudioModulation?, at time: Double,
                                settings: SceneSettings, features: AudioFeatures?) -> Double {
        var value = base
        if let modulation {
            let signal = modulation.signal(at: time, settings: settings, features: features)
            if modulation.blend == .add { value += modulation.amount * signal }
            else { value *= 1 + modulation.amount / 100 * signal }
        }
        if let range = parameter.valueRange { value = min(range.upperBound, max(range.lowerBound, value)) }
        if parameter == .scale { value = max(0.1, value) }
        if parameter.rawValue.hasSuffix("Count") { value = value.rounded() }
        return value
    }

    static func plotSamples(_ parameter: ImageParameter, clip: VisualClip, from first: Double, through last: Double,
                            steps: Int, settings: SceneSettings, features: AudioFeatures?) -> [(Double, Double)] {
        let modulation = clip.audioModulations[parameter]
        let events = Set(modulation?.events(from: first, through: last, settings: settings, features: features) ?? [])
        let manual = clip.curve(parameter)?.plotSamples(from: first - clip.start, through: last - clip.start, steps: steps) ?? []
        let groups = Dictionary(grouping: manual, by: { clip.start + $0.0 })
        var times = Set(groups.keys).union(events)
        let count = max(1, steps)
        for index in 0...count { times.insert(first + (last - first) * Double(index) / Double(count)) }
        var result: [(Double, Double)] = []
        for time in times.sorted() {
            let entries = groups[time]?.map { $0.1 }
            let after = entries?.last ?? clip.manualValue(parameter, at: time)
            if time > first, events.contains(time) || (entries?.count ?? 0) > 1 {
                let before = entries?.first ?? after
                let evaluationTime = events.contains(time) ? time - max(1e-10, abs(time) * Double.ulpOfOne * 32) : time
                result.append((time, combine(before, parameter: parameter, modulation: modulation, at: evaluationTime, settings: settings, features: features)))
            }
            result.append((time, combine(after, parameter: parameter, modulation: modulation, at: time, settings: settings, features: features)))
        }
        return result
    }
}

extension VisualClip {
    var automationParameters: Set<ImageParameter> { Set(curves.map(\.parameter)).union(audioModulations.keys) }
    func displayCurve(_ parameter: ImageParameter) -> ImageCurve? {
        if let curve = curve(parameter) { return curve }
        guard audioModulations[parameter] != nil else { return nil }
        var curve = ImageCurve(parameter: parameter)
        if let range = automationRanges[parameter] { curve.minimum = range.lower; curve.maximum = range.upper }
        return curve
    }
    mutating func removeAudioAndKeys(_ parameter: ImageParameter) {
        curves.removeAll { $0.parameter == parameter }
        audioModulations[parameter] = nil
        automationRanges[parameter] = nil
    }
    struct DisplayRange: Codable, Equatable, Sendable {
        var lower: Double
        var upper: Double
    }

    mutating func setDisplayCurve(_ curve: ImageCurve) {
        if self.curve(curve.parameter) != nil || !curve.keys.isEmpty { setCurve(curve) }
        else { automationRanges[curve.parameter] = DisplayRange(lower: curve.minimum, upper: curve.maximum) }
    }
}
