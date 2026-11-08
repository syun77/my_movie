import Foundation

struct TimelineSnapGrid {
    var bpm = 120.0
    var origin = 0.0
    var step: Double { 15 / bpm }

    func nearest(_ time: Double) -> Double {
        origin + ((time - origin) / step).rounded() * step
    }

    func snap(_ time: Double, within range: ClosedRange<Double>) throws -> Double {
        let first = ceil((range.lowerBound - origin) / step - 1e-9)
        let last = floor((range.upperBound - origin) / step + 1e-9)
        guard first <= last else { throw StudioError.message("16分音符単位で配置できる空き時間がありません。") }
        return origin + max(first, min(last, ((time - origin) / step).rounded())) * step
    }
}
