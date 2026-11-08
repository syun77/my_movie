import Foundation

struct TimelineDisplaySettings {
    static let defaultSpan = 12.0
    static let spanRange = 2.0...300.0
    private let defaults: UserDefaults
    private let spanKey = "timelineVisibleSpan"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var showsWholeSong: Bool {
        get { defaults.bool(forKey: "timelineShowsWholeSong") }
        nonmutating set { defaults.set(newValue, forKey: "timelineShowsWholeSong") }
    }

    var imageMode: Bool {
        get { defaults.bool(forKey: "timelineImageMode") }
        nonmutating set { defaults.set(newValue, forKey: "timelineImageMode") }
    }

    var visibleSpan: Double {
        get {
            guard let value = defaults.object(forKey: spanKey) as? Double,
                  value.isFinite, Self.spanRange.contains(value) else { return Self.defaultSpan }
            return value
        }
        nonmutating set {
            guard newValue.isFinite, Self.spanRange.contains(newValue) else { return }
            defaults.set(newValue, forKey: spanKey)
        }
    }
}
