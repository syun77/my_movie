import AVFoundation
import Accelerate

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum AudioAnalyzer {
    static func analyze(url: URL) throws -> AudioFeatures {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        guard duration > 0, duration.isFinite else { throw StudioError.message("音声が空です。") }
        let count = 2048
        let step = 1.0 / 30.0
        guard let fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw StudioError.message("音声解析を初期化できません。")
        }
        defer { vDSP_DFT_DestroySetup(fft) }
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        let imaginary = [Float](repeating: 0, count: count)
        var realOut = imaginary
        var imagOut = imaginary
        var frames = [[Float]]()
        var smooth = [Float](repeating: 0, count: 32)
        for index in 0..<Int(ceil(duration / step)) {
            try Task.checkCancellation()
            let center = Int64(Double(index) * step * rate)
            let start = max(0, center - Int64(count / 2))
            file.framePosition = start
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(count), file.length - start)))
            guard let channels = buffer.floatChannelData else { throw StudioError.message("音声データを取得できません。") }
            var power = [Float](repeating: 0, count: count / 2)
            let pad = max(0, count / 2 - Int(center))
            for channel in 0..<Int(file.processingFormat.channelCount) {
                var input = [Float](repeating: 0, count: count)
                for sample in 0..<min(Int(buffer.frameLength), count - pad) { input[sample + pad] = channels[channel][sample] * window[sample + pad] }
                vDSP_DFT_Execute(fft, input, imaginary, &realOut, &imagOut)
                for bin in 0..<power.count {
                    power[bin] += (realOut[bin] * realOut[bin] + imagOut[bin] * imagOut[bin]) / Float(file.processingFormat.channelCount * UInt32(count * count))
                }
            }
            let top = min(20000, rate / 2)
            for band in 0..<32 {
                let low = 20 * pow(top / 20, Double(band) / 32)
                let high = 20 * pow(top / 20, Double(band + 1) / 32)
                let first = min(count / 2 - 1, max(1, Int(low * Double(count) / rate)))
                let last = min(count / 2, max(first + 1, Int(high * Double(count) / rate)))
                let sum = power[first..<last].reduce(0, +)
                let normalized = max(0, min(1, (10 * log10(max(sum, 1e-10)) + 70) / 70))
                let factor: Float = normalized > smooth[band] ? 0.8 : 0.22
                smooth[band] += (normalized - smooth[band]) * factor
            }
            frames.append(smooth)
        }
        return AudioFeatures(duration: duration, step: step, frames: frames)
    }
}
