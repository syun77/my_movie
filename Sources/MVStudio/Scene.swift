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
    var transientEvents: [TransientBand: [Double]] = [:]
    var sampleRate = 48000.0

    func events(for band: TransientBand) -> [Double] { transientEvents[band.key] ?? [] }
    private func insertionIndex(_ time: Double, in times: [Double], afterEqual: Bool) -> Int {
        var lower = 0, upper = times.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if times[middle] < time || (afterEqual && times[middle] == time) { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    func transientEvents(for band: TransientBand, from first: Double, through last: Double) -> [Double] {
        let times = events(for: band)
        let start = insertionIndex(first, in: times, afterEqual: false)
        let end = insertionIndex(last, in: times, afterEqual: true)
        return start <= end ? Array(times[start..<end]) : []
    }
    func latestTransient(at time: Double, band: TransientBand) -> Double? {
        guard time >= 0, time < duration else { return nil }
        let times = events(for: band)
        let index = insertionIndex(time, in: times, afterEqual: true)
        return index > 0 ? times[index - 1] : nil
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
