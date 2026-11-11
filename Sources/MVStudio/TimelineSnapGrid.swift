import Foundation

enum TimelineSnapDivision: Int, CaseIterable {
    case whole = 1
    case half = 2
    case quarter = 4
    case eighth = 8
    case sixteenth = 16

    var title: String { self == .whole ? "全音符" : "\(rawValue)分音符" }
}

struct TimelineSnapGrid {
    var bpm = 120.0
    var origin = 0.0
    var division: TimelineSnapDivision = .sixteenth
    var step: Double { 240 / bpm / Double(division.rawValue) }

    func nearest(_ time: Double) -> Double {
        origin + ((time - origin) / step).rounded() * step
    }

    func snap(_ time: Double, within range: ClosedRange<Double>) throws -> Double {
        let first = ceil((range.lowerBound - origin) / step - 1e-9)
        let last = floor((range.upperBound - origin) / step + 1e-9)
        guard first <= last else { throw StudioError.message("\(division.title)単位で配置できる空き時間がありません。") }
        return origin + max(first, min(last, ((time - origin) / step).rounded())) * step
    }
}
