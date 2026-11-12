import AVFoundation

enum TransientDetector {
    static let fixedBands = [TransientBand(kind: .low), TransientBand(kind: .mid), TransientBand(kind: .high)]

    static func detect(in file: AVAudioFile, bands: [TransientBand] = fixedBands,
                       check: () throws -> Void = { try Task.checkCancellation() }) throws -> [TransientBand: [Double]] {
        let rate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        let blockSize = max(1, Int((rate * 0.005).rounded()))
        let blockDuration = Double(blockSize) / rate
        let attack = 1 - exp(-blockDuration / 0.015)
        let release = exp(-blockDuration / 0.08)
        let keys = Array(Set(bands.map(\.key))).filter { $0.kind != .all }
        var detectors = keys.map { band in BandState(range: band.bounds(sampleRate: rate), rate: rate, channels: channels) }
        var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, [Double]()) })
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(blockSize * 64)),
              let samples = buffer.floatChannelData else { throw StudioError.message("トランジェント解析を初期化できません。") }
        file.framePosition = 0
        while file.framePosition < file.length {
            try check()
            let first = file.framePosition
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            for start in stride(from: 0, to: count, by: blockSize) {
                let end = min(count, start + blockSize)
                let time = Double(first + Int64(start)) / rate
                for index in keys.indices where detectors[index].available {
                    var power = 0.0
                    for channel in 0..<channels {
                        for sample in start..<end {
                            let value = detectors[index].filter(Double(samples[channel][sample]), channel: channel)
                            power += value * value
                        }
                    }
                    power /= Double((end - start) * channels)
                    let baseline = detectors[index].envelope
                    if power >= max(baseline * 2.2, baseline + 0.000004), time - detectors[index].last >= 0.065 {
                        result[keys[index], default: []].append(time)
                        detectors[index].last = time
                    }
                    detectors[index].envelope = max(baseline + (power - baseline) * attack, baseline * release)
                }
            }
        }
        return result
    }

    private struct BandState {
        var available: Bool
        var high: [[Biquad]]
        var low: [[Biquad]]
        var envelope = 0.0
        var last = -Double.infinity
        init(range: ClosedRange<Double>?, rate: Double, channels: Int) {
            available = range != nil
            let quality = (0..<4).map { 1 / (2 * cos(Double(2 * $0 + 1) * .pi / 16)) }
            high = Array(repeating: quality.map { Biquad(frequency: range?.lowerBound ?? 20, rate: rate, highpass: true, quality: $0) }, count: channels)
            low = Array(repeating: quality.map { Biquad(frequency: range?.upperBound ?? min(180, rate * 0.499), rate: rate, highpass: false, quality: $0) }, count: channels)
        }
        mutating func filter(_ sample: Double, channel: Int) -> Double {
            var value = sample
            for stage in high[channel].indices { value = high[channel][stage].process(value) }
            for stage in low[channel].indices { value = low[channel][stage].process(value) }
            return value
        }
    }
    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        init(frequency: Double, rate: Double, highpass: Bool, quality: Double) {
            let w = 2 * Double.pi * min(rate * 0.499, frequency) / rate
            let c = cos(w), alpha = sin(w) / (2 * quality), a0 = 1 + alpha
            b0 = (highpass ? 1 + c : 1 - c) / 2 / a0
            b1 = (highpass ? -(1 + c) : 1 - c) / a0
            b2 = b0
            a1 = -2 * c / a0; a2 = (1 - alpha) / a0
        }
        mutating func process(_ input: Double) -> Double {
            let value = b0 * input + z1
            z1 = b1 * input - a1 * value + z2
            z2 = b2 * input - a2 * value
            return value
        }
    }
}

actor TransientAnalysisService {
    static let shared = TransientAnalysisService()
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
        let lower: Double
        let upper: Double
        let union: Bool
    }
    private var cache: [Key: [Double]] = [:]
    private var order: [Key] = []
    private struct Pending {
        let id: UUID
        let task: Task<Void, Never>
        var waiters = 0
        var result: Result<[Double], Error>?
    }
    private var pending: [Key: Pending] = [:]

    private func finish(_ key: Key, id: UUID, result: Result<[Double], Error>) {
        guard pending[key]?.id == id else { return }
        pending[key]?.result = result
    }
    private func release(_ key: Key, id: UUID) {
        guard pending[key]?.id == id else { return }
        pending[key]?.waiters -= 1
        if pending[key]?.waiters == 0 { pending[key]?.task.cancel(); pending[key] = nil }
    }
    private func analyze(_ key: Key, band: TransientBand, url: URL, cancellation: ExportCancellation?) async throws -> [Double] {
        if pending[key] == nil {
            let id = UUID()
            let task = Task.detached { [weak self] in
                let result = Result {
                    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                    let bands = band.kind == .all ? TransientDetector.fixedBands : [band]
                    let events = try TransientDetector.detect(in: file, bands: bands)
                    return band.kind == .all ? Array(Set(events.values.flatMap { $0 })).sorted() : events[band] ?? []
                }
                await self?.finish(key, id: id, result: result)
            }
            pending[key] = Pending(id: id, task: task)
        }
        let id = pending[key]!.id
        pending[key]?.waiters += 1
        defer { release(key, id: id) }
        while true {
            try Task.checkCancellation(); try cancellation?.check()
            if let result = pending[key]?.result { return try result.get() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func prepare(_ features: AudioFeatures, url: URL, bands: Set<TransientBand>, cancellation: ExportCancellation? = nil) async throws -> AudioFeatures {
        var result = features
        let retained = bands.union(TransientDetector.fixedBands).union([TransientBand()])
        result.transientEvents = result.transientEvents.filter { retained.contains($0.key) }
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        for band in bands.map(\.key) where result.transientEvents[band] == nil {
            try Task.checkCancellation(); try cancellation?.check()
            guard let range = band.bounds(sampleRate: result.sampleRate) else { result.transientEvents[band] = []; continue }
            if band.kind != .all, let same = result.transientEvents.first(where: { $0.key.kind != .all && $0.key.bounds(sampleRate: result.sampleRate) == range }) {
                result.transientEvents[band] = same.value; continue
            }
            let key = Key(url: url, modified: attributes.contentModificationDate, size: attributes.fileSize,
                          lower: range.lowerBound, upper: range.upperBound, union: band.kind == .all)
            if let found = cache[key] {
                result.transientEvents[band] = found
                order.removeAll { $0 == key }; order.append(key)
                continue
            }
            let values = try await analyze(key, band: band, url: url, cancellation: cancellation)
            cache[key] = values; order.removeAll { $0 == key }; order.append(key)
            while order.count > 16 || cache.values.reduce(0, { $0 + $1.count * MemoryLayout<Double>.stride }) > 32 * 1024 * 1024 {
                guard let oldest = order.first else { break }
                order.removeFirst(); cache[oldest] = nil
            }
            try Task.checkCancellation(); try cancellation?.check()
            result.transientEvents[band] = values
        }
        return result
    }
}

extension VisualTrack {
    var requiredTransientBands: Set<TransientBand> {
        Set(clips.flatMap { $0.audioModulations.values }.filter { $0.enabled && $0.source == .transient }.map { $0.transientBand.key })
    }
}
