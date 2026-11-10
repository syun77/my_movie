import Foundation
import simd

struct ImageEffects: Codable, Equatable, Sendable {
    var blur: Blur?
    var bloom: Bloom?
    var particles: Particles?
    var embers: Embers?

    struct Blur: Codable, Equatable, Sendable {
        var isEnabled = true
        var radius = 8.0
        static let radiusRange = 0.0...64
    }

    struct Bloom: Codable, Equatable, Sendable {
        var isEnabled = true
        var threshold = 65.0
        var radius = 24.0
        var intensity = 60.0
        static let thresholdRange = 0.0...100
        static let radiusRange = 1.0...96
        static let intensityRange = 0.0...200
    }

    struct Particles: Codable, Equatable, Sendable {
        struct Emitter: Codable, Equatable, Sendable {
            var x = 960.0
            var y = 508.0
            var phaseSeed: UInt32 = 0

            static let xRange = 0.0...Double(VideoExporter.width)
            static let yRange = 0.0...Double(VideoExporter.height)

            var isValid: Bool { Self.xRange.contains(x) && Self.yRange.contains(y) }
        }

        static let emitterLimit = 4
        var isEnabled = true
        var count = 90.0
        var diameter = 8.0
        var speed = 60.0
        var curveStrength = Self.defaultCurveStrength
        var color = RGBColor(red: 0.48, green: 0.68, blue: 1)
        var opacity = 65.0
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0
        var emitters = [Emitter()]
        static let countRange = 1.0...200
        static let diameterRange = 2.0...32
        static let speedRange = 0.0...300
        static let defaultCurveStrength = 100.0
        static let curveStrengthRange = 0.0...200
        static let opacityRange = 0.0...100

        mutating func addEmitter() {
            guard emitters.count < Self.emitterLimit else { return }
            let candidates = [Emitter(x: 1440), Emitter(x: 480), Emitter(y: 810), Emitter()]
            guard var emitter = candidates.first(where: { point in
                !emitters.contains { $0.x == point.x && $0.y == point.y }
            }) else { return }
            emitter.phaseSeed = UInt32.random(in: 1 ... .max)
            emitters.append(emitter)
        }

        func instances(at localTime: Double, size: SIMD2<Double>, emitter: Emitter? = nil) -> [SIMD4<Float>] {
            let emitter = emitter ?? emitters[0]
            let time = localTime + phaseOffset
            let motionTime = (time + Double(emitter.phaseSeed) / 4_294_967_296 * 8) * (speed / 60)
            let center = SIMD2(emitter.x / Double(VideoExporter.width), emitter.y / Double(VideoExporter.height))
            let sourceSeed = seed &+ emitter.phaseSeed
            let bend = curveStrength / 100
            let light = opacity / 100

            func orbit(at time: Double) -> SIMD2<Double> {
                let angle = time * 1.38
                return size * SIMD2(
                    center.x + 0.23 * cos(angle) + bend * 0.045 * sin(angle * 2.3),
                    center.y + bend * (0.17 * sin(angle * 1.31) + 0.065 * cos(angle * 2.1))
                )
            }

            let head = orbit(at: motionTime)
            let pulse = 0.94 + 0.06 * cos(time * 14)
            var instances = [SIMD4(Float(head.x), Float(head.y), Float(diameter * 3.4), Float(light * pulse))]
            instances.reserveCapacity(Int(count))

            for index in 1..<Int(count) {
                func random(_ channel: UInt32) -> Double {
                    ImageEffects.random(seed: sourceSeed, index: index, channel: channel)
                }
                let life = 1.15 + 1.45 * random(0)
                let age = ImageEffects.wrap(motionTime + life * random(1), length: life)
                let progress = age / life
                let lag = age * (0.74 + 0.20 * random(2))
                let scatter = SIMD2((random(3) - 0.5) * 94,
                                    bend * ((random(4) - 0.5) * 78 + 22 * age)) * age
                let position = orbit(at: motionTime - lag) + scatter

                let fadeIn = min(1, progress * 8)
                let fadeOut = pow(1 - progress, 1.35)
                let twinkle = 0.72 + 0.28 * cos(time * (14 + 18 * random(5)) + random(6) * 2 * .pi)
                let brightness = light * fadeIn * fadeOut * twinkle * (0.42 + 0.58 * random(7))
                let sparkDiameter = diameter * (0.55 + 1.25 * random(8))
                instances.append(SIMD4(Float(position.x), Float(position.y), Float(sparkDiameter), Float(brightness)))
            }
            return instances
        }
    }

    struct Embers: Codable, Equatable, Sendable {
        var isEnabled = true
        var count = 90.0
        var diameter = 20.0
        var riseSpeed = 160.0
        var wind = 24.0
        var swaySpeed = Self.defaultSwaySpeed
        var brightness = 85.0
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        static let countRange = 1.0...200
        static let diameterRange = 4.0...80
        static let riseSpeedRange = 20.0...420
        static let windRange = -240.0...240
        static let defaultSwaySpeed = 40.0
        static let swaySpeedRange = 0.0...200
        static let brightnessRange = 0.0...100

        var isValid: Bool {
            Self.countRange.contains(count) && count == count.rounded()
                && Self.diameterRange.contains(diameter) && Self.riseSpeedRange.contains(riseSpeed)
                && Self.windRange.contains(wind) && Self.swaySpeedRange.contains(swaySpeed)
                && Self.brightnessRange.contains(brightness)
                && phaseOffset.isFinite && abs(phaseOffset) <= Double.greatestFiniteMagnitude / 1024
        }

        func instances(at localTime: Double, size: SIMD2<Double>) -> [SIMD4<Float>] {
            let time = localTime + phaseOffset
            let swayRate = swaySpeed / 100
            return (0..<Int(count)).map { index in
                func random(_ channel: UInt32) -> Double {
                    ImageEffects.random(seed: seed, index: index, channel: channel)
                }
                let depth = random(0)
                let glowDiameter = diameter * (0.45 + 1.3 * depth)
                let velocity = riseSpeed * (0.55 + 0.85 * depth)
                let lifetime = size.y * (0.45 + 0.65 * random(1)) / velocity
                let cycles = time / lifetime + random(2)
                let cycle = floor(cycles)
                let progress = cycles - cycle
                let age = progress * lifetime
                let cycleIndex = Int64(cycle.truncatingRemainder(dividingBy: 4_294_967_296))
                let birthSeed = seed &+ UInt32(truncatingIfNeeded: cycleIndex) &* 0xD1B54A35
                let birthX = ImageEffects.random(seed: birthSeed, index: index, channel: 3) * size.x
                let birthY = (0.88 + 0.14 * random(4)) * size.y
                let birth = SIMD2(birthX, birthY)
                let travel = SIMD2(wind * (0.6 + depth * 0.6), -velocity) * age
                let drift = birth + travel
                let fieldOrigin = birth / 190
                let fieldTravel = travel / 190 + SIMD2(0.25, -0.35) * age
                let turbulence: SIMD2<Double>
                if swayRate > 0 {
                    let field = fieldOrigin + fieldTravel * swayRate
                    let broad = Self.flow(at: field, seed: seed)
                    let detail = Self.detail(at: field, age: age * swayRate, seed: seed)
                    turbulence = (broad * (28 + 42 * depth) + detail * (8 + 12 * depth)) * Self.ease(0, 0.3, age)
                } else {
                    turbulence = .zero
                }
                let x = ImageEffects.wrap(drift.x + turbulence.x + glowDiameter / 2,
                                          length: size.x + glowDiameter) - glowDiameter / 2
                let y = drift.y + turbulence.y * 0.45
                let fade = Self.ease(0, 0.14, progress) * (1 - Self.ease(0.28, 1, progress))
                let flicker = 0.82 + 0.18 * Self.detail(at: fieldOrigin + fieldTravel, age: age, seed: seed).y
                let light = brightness / 100 * (0.38 + 0.62 * depth) * flicker * fade
                return SIMD4(Float(x), Float(y), Float(glowDiameter), Float(light))
            }
        }

        private static func detail(at field: SIMD2<Double>, age: Double, seed: UInt32) -> SIMD2<Double> {
            flow(at: field * 2.8 + SIMD2(age * 0.7, 11), seed: seed &+ 1)
        }

        // A continuous, seeded value-noise field sampled at the particle's position.
        private static func flow(at point: SIMD2<Double>, seed: UInt32) -> SIMD2<Double> {
            let x = floor(point.x), y = floor(point.y)
            let fraction = point - SIMD2(x, y)
            let blend = fraction * fraction * (3 - 2 * fraction)
            func corner(_ dx: Int, _ dy: Int) -> SIMD2<Double> {
                let column = UInt32(truncatingIfNeeded: Int(x) + dx)
                let row = Int(y) + dy
                let cellSeed = seed &+ column &* 0xD1B54A35
                return SIMD2(ImageEffects.random(seed: cellSeed, index: row, channel: 0),
                             ImageEffects.random(seed: cellSeed, index: row, channel: 1))
            }
            let top = corner(0, 0) * (1 - blend.x) + corner(1, 0) * blend.x
            let bottom = corner(0, 1) * (1 - blend.x) + corner(1, 1) * blend.x
            return (top * (1 - blend.y) + bottom * blend.y) * 2 - 1
        }

        private static func ease(_ start: Double, _ end: Double, _ value: Double) -> Double {
            let t = min(1, max(0, (value - start) / (end - start)))
            return t * t * (3 - 2 * t)
        }
    }

    private static func random(seed: UInt32, index: Int, channel: UInt32) -> Double {
        var value = seed &+ UInt32(truncatingIfNeeded: index) &* 0x9E3779B9 &+ channel &* 0x85EBCA6B
        value ^= value >> 16
        value &*= 0x7FEB352D
        value ^= value >> 15
        value &*= 0x846CA68B
        value ^= value >> 16
        return Double(value) / 4_294_967_296
    }

    private static func wrap(_ value: Double, length: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: length)
        return remainder < 0 ? remainder + length : remainder
    }

    var isValid: Bool {
        if let blur, !Blur.radiusRange.contains(blur.radius) { return false }
        if let bloom, !(Bloom.thresholdRange.contains(bloom.threshold) && Bloom.radiusRange.contains(bloom.radius)
                        && Bloom.intensityRange.contains(bloom.intensity)) { return false }
        if let particles, !(Particles.countRange.contains(particles.count) && particles.count == particles.count.rounded()
                           && Particles.diameterRange.contains(particles.diameter) && Particles.speedRange.contains(particles.speed)
                           && Particles.curveStrengthRange.contains(particles.curveStrength)
                           && Particles.opacityRange.contains(particles.opacity) && particles.color.isValid
                           && (1...Particles.emitterLimit).contains(particles.emitters.count)
                           && particles.emitters.allSatisfy(\.isValid)
                           && particles.phaseOffset.isFinite && abs(particles.phaseOffset) <= Double.greatestFiniteMagnitude / 1024) { return false }
        return embers?.isValid != false
    }
}

extension ImageEffects.Particles {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        count = try values.decode(Double.self, forKey: .count)
        diameter = try values.decode(Double.self, forKey: .diameter)
        speed = try values.decode(Double.self, forKey: .speed)
        curveStrength = try values.decodeIfPresent(Double.self, forKey: .curveStrength) ?? Self.defaultCurveStrength
        color = try values.decode(RGBColor.self, forKey: .color)
        opacity = try values.decode(Double.self, forKey: .opacity)
        seed = try values.decode(UInt32.self, forKey: .seed)
        phaseOffset = try values.decode(Double.self, forKey: .phaseOffset)
        emitters = try values.decodeIfPresent([Emitter].self, forKey: .emitters) ?? [Emitter()]
    }
}

extension ImageEffects.Embers {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        count = try values.decode(Double.self, forKey: .count)
        diameter = try values.decode(Double.self, forKey: .diameter)
        riseSpeed = try values.decode(Double.self, forKey: .riseSpeed)
        wind = try values.decode(Double.self, forKey: .wind)
        swaySpeed = try values.decodeIfPresent(Double.self, forKey: .swaySpeed) ?? Self.defaultSwaySpeed
        brightness = try values.decode(Double.self, forKey: .brightness)
        seed = try values.decode(UInt32.self, forKey: .seed)
        phaseOffset = try values.decode(Double.self, forKey: .phaseOffset)
    }
}
