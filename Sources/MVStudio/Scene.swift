import Foundation

struct SceneSettings: Codable, Sendable, Equatable {
    var bpm: Double
    var beatOffset: Double
    var spectrum: Bool
    var spectrumStyle: SpectrumStyle

    init(bpm: Double = 120, beatOffset: Double = 0, spectrum: Bool = true, spectrumStyle: SpectrumStyle = SpectrumStyle()) {
        self.bpm = bpm
        self.beatOffset = beatOffset
        self.spectrum = spectrum
        self.spectrumStyle = spectrumStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try container.decode(Double.self, forKey: .bpm)
        beatOffset = try container.decode(Double.self, forKey: .beatOffset)
        spectrum = try container.decode(Bool.self, forKey: .spectrum)
        spectrumStyle = try container.decodeIfPresent(SpectrumStyle.self, forKey: .spectrumStyle) ?? SpectrumStyle()
    }
}

struct AudioFeatures: Sendable {
    let duration: Double
    let step: Double
    let frames: [[Float]]
    let transientTimes: [Double]

    func transientPulse(at time: Double) -> Double {
        guard time >= 0, time < duration else { return 0 }
        var lower = 0
        var upper = transientTimes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if transientTimes[middle] <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return 0 }
        return zoomPulse(elapsed: time - transientTimes[lower - 1])
    }

    func bands(at time: Double, count: Int) -> [Float] {
        let levels = spectrumLevels(at: time)
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { band in
            let lower = band * levels.count / count
            let upper = max(lower + 1, (band + 1) * levels.count / count)
            return levels[lower..<upper].max() ?? 0
        }
    }

    func bandEdges(at time: Double, count: Int) -> [Float] {
        let levels = spectrumLevels(at: time)
        guard !levels.isEmpty else { return Array(repeating: 0, count: count + 1) }
        let binsPerBand = Double(levels.count) / Double(count)
        return (0...count).map { edge in
            // Interpolate between adjacent bin centers at each display boundary.
            let position = min(Double(levels.count - 1), max(0, Double(edge) * binsPerBand - 0.5))
            let lower = Int(position)
            let upper = min(lower + 1, levels.count - 1)
            let fraction = Float(position - Double(lower))
            return levels[lower] + (levels[upper] - levels[lower]) * fraction
        }
    }

    private func spectrumLevels(at time: Double) -> [Float] {
        guard let first = frames.first, !first.isEmpty, time >= 0, time < duration else { return [] }
        let position = time / step
        let index = min(Int(position), frames.count - 1)
        let next = min(index + 1, frames.count - 1)
        let fraction = Float(position - Double(index))
        let current = frames[index]
        let following = frames[next]
        return current.indices.map { current[$0] + (following[$0] - current[$0]) * fraction }
    }
}
