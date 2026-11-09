import AVFoundation

enum TransientDetector {
    static func detect(in file: AVAudioFile) throws -> [Double] {
        let format = file.processingFormat
        let rate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let blockSize = max(1, Int((rate * 0.005).rounded()))
        let blockDuration = Double(blockSize) / rate
        let attack = Float(1 - exp(-blockDuration / 0.015))
        let release = Float(exp(-blockDuration / 0.08))
        let lowResponse = Float(1 - exp(-2 * .pi * 180 / rate))
        let midResponse = Float(1 - exp(-2 * .pi * 2400 / rate))
        // Ignore power increases below -54 dBFS.
        let minimumRise: Float = 0.000004
        let minimumPowerRatio: Float = 2.2
        let minimumInterval = 0.065
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockSize * 64)),
              let channels = buffer.floatChannelData else {
            throw StudioError.message("トランジェント解析を初期化できません。")
        }
        file.framePosition = 0
        var filters = [BandFilter](repeating: BandFilter(), count: channelCount)
        var envelope = SIMD3<Float>.zero
        var times: [Double] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let firstFrame = file.framePosition
            try file.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            for start in stride(from: 0, to: frameCount, by: blockSize) {
                let end = min(frameCount, start + blockSize)
                var power = SIMD3<Float>.zero
                for channel in 0..<channelCount {
                    var filter = filters[channel]
                    for sample in start..<end {
                        let bands = filter.split(channels[channel][sample], lowResponse: lowResponse, midResponse: midResponse)
                        power += bands * bands
                    }
                    filters[channel] = filter
                }
                power /= Float((end - start) * channelCount)
                let time = Double(firstFrame + Int64(start)) / rate
                var triggered = false
                for band in 0..<3 {
                    let baseline = envelope[band]
                    if power[band] >= max(baseline * minimumPowerRatio, baseline + minimumRise) {
                        triggered = true
                    }
                    envelope[band] = max(baseline + (power[band] - baseline) * attack, baseline * release)
                }
                if triggered, time - (times.last ?? -.infinity) >= minimumInterval {
                    times.append(time)
                }
            }
        }
        return times
    }

    private struct BandFilter {
        var low: Float = 0
        var lowAndMid: Float = 0

        mutating func split(_ sample: Float, lowResponse: Float, midResponse: Float) -> SIMD3<Float> {
            low += (sample - low) * lowResponse
            lowAndMid += (sample - lowAndMid) * midResponse
            return SIMD3(low, lowAndMid - low, sample - lowAndMid)
        }
    }
}
