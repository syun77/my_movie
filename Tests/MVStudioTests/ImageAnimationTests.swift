import AppKit
import XCTest
@testable import MVStudio

final class ImageAnimationTests: XCTestCase {
    @MainActor private func automationMenu(_ field: DragValueField) -> NSMenu? {
        if field.bounds.isEmpty { field.setFrameSize(NSSize(width: 90, height: 24)) }
        let event = NSEvent.mouseEvent(with: .rightMouseDown,
            location: field.convert(NSPoint(x: 11, y: field.bounds.midY), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: field.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        return field.menu(for: event)
    }

    @MainActor private func performAutomationMenu(_ field: DragValueField, title: String) throws {
        let menu = try XCTUnwrap(automationMenu(field))
        XCTAssertEqual(menu.items.first?.title, title)
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private func fixture(slot: Int = 3) throws -> (VisualTrack, VisualClip) {
        var track = VisualTrack()
        let asset = track.register(url: URL(fileURLWithPath: "/tmp/animation.png"), projectURL: URL(fileURLWithPath: "/tmp/animation.mvproject"))
        let added = try track.adding(assetID: asset, at: 1, slot: slot, duration: 10, grid: TimelineSnapGrid())
        return (added.track, added.clip)
    }

    func testEffectAutomationEvaluationPersistenceAndTrim() throws {
        var (_, clip) = try fixture()
        clip.effects = ImageEffects(blur: .init(), bloom: .init(), particles: .init(seed: 1),
                                   embers: .init(seed: 2), snow: .init(seed: 3), orbs: .init())
        for parameter in ImageParameter.allCases where parameter.effect != nil {
            let effect = try XCTUnwrap(parameter.effect)
            guard effect.read(clip.effects!) != nil else { continue }
            _ = clip.setKey(parameter, at: clip.start, value: effect.range.lowerBound)
            _ = clip.setKey(parameter, at: clip.end, value: effect.range.upperBound)
        }
        let midpoint = (clip.start + clip.end) / 2
        let evaluated = try XCTUnwrap(clip.evaluatedEffects(at: midpoint))
        for curve in clip.curves {
            let effect = try XCTUnwrap(curve.parameter.effect)
            XCTAssertEqual(try XCTUnwrap(effect.read(evaluated)),
                           curve.parameter.rawValue.hasSuffix("Count") ? ((effect.range.lowerBound + effect.range.upperBound) / 2).rounded() : (effect.range.lowerBound + effect.range.upperBound) / 2, accuracy: 1e-8)
        }
        let decoded = try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(decoded, clip)
        clip.trimStart(to: clip.start + 0.2)
        XCTAssertEqual(clip.evaluatedEffects(at: midpoint)?.blur, evaluated.blur)
        XCTAssertEqual(clip.evaluatedEffects(at: midpoint)?.orbs?.opacity, evaluated.orbs?.opacity)
        var ids = Set<UUID>()
        try clip.validateAnimation(ids: &ids)
    }

    @MainActor func testEffectFieldCreatesDeletesAndRestoresAutomation() throws {
        _ = NSApplication.shared
        let editor = VisualEditor()
        let timeline = TimelineView(frame: .zero)
        editor.timeline = timeline
        var (track, clip) = try fixture()
        clip.effects = ImageEffects(blur: .init())
        track = try track.updating(clip, slot: 3, duration: 10)
        editor.duration = 10
        editor.load(track, projectURL: nil)
        editor.setAvailable(true)
        timeline.onImageSelect?(clip.id, 3)
        editor.currentTime = 2
        let field = try XCTUnwrap(control("visuals.value.blurRadius", in: editor.view) as DragValueField?)
        XCTAssertFalse(field.hasAutomation)
        try performAutomationMenu(field, title: "オートメーションを作成")
        XCTAssertTrue(field.hasAutomation)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.blurRadius)?.keys.first?.value, 8)
        let automated = editor.track
        try performAutomationMenu(field, title: "オートメーションを削除")
        XCTAssertFalse(field.hasAutomation)
        XCTAssertNil(editor.track.clip(clip.id)?.curve(.blurRadius))
        XCTAssertEqual(editor.track.clip(clip.id)?.effects?.blur?.radius, 8)
        editor.restore(automated)
        XCTAssertTrue(field.hasAutomation)
        var restored = try XCTUnwrap(editor.track.clip(clip.id))
        restored.effects?.blur = nil
        editor.restore(try automated.updating(restored, slot: 3, duration: 10))
        XCTAssertFalse(field.isEnabled)
    }

    func testEffectBaseShiftStaysWithinPhysicalLimits() throws {
        var (_, clip) = try fixture()
        clip.effects = ImageEffects(blur: .init())
        _ = clip.setKey(.blurRadius, at: clip.start, value: 0)
        _ = clip.setKey(.blurRadius, at: clip.end, value: 64)
        clip.setBaseValue(16, for: .blurRadius)
        XCTAssertEqual(clip.baseValue(.blurRadius), 16)
        XCTAssertEqual(clip.curve(.blurRadius)?.keys.map(\.value), [8, 64])
        clip.effects?.snow = .init(seed: 0)
        let key = clip.setKey(.snowCount, at: clip.start, value: 50.5)
        clip.removeKey(key, parameter: .snowCount)
        XCTAssertEqual(clip.effects?.snow?.count, 51)
        XCTAssertTrue(clip.effects?.isValid == true)
        var ids = Set<UUID>()
        try clip.validateAnimation(ids: &ids)
    }

    @MainActor func testOpacityBaseAutomationAndPersistence() throws {
        _ = NSApplication.shared
        let editor = VisualEditor()
        let timeline = TimelineView(frame: .zero)
        editor.timeline = timeline
        let (track, clip) = try fixture()
        editor.duration = 10; editor.load(track, projectURL: nil); editor.setAvailable(true)
        timeline.onImageSelect?(clip.id, 3); editor.currentTime = 2
        let field = try XCTUnwrap(control("visuals.value.opacity", in: editor.view) as DragValueField?)
        XCTAssertEqual(field.doubleValue, 100)
        field.stringValue = "50"
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.opacity), 50)
        try performAutomationMenu(field, title: "オートメーションを作成")
        XCTAssertTrue(field.hasAutomation)
        var changed = try XCTUnwrap(editor.track.clip(clip.id))
        let first = try XCTUnwrap(changed.curve(.opacity)?.keys.first?.id)
        _ = changed.setKey(.opacity, at: 3, value: 100)
        var curve = try XCTUnwrap(changed.curve(.opacity))
        curve.adjustMidpoint(after: first, handleValue: 100)
        changed.setCurve(curve)
        for index in 0...100 { XCTAssertTrue((0...100).contains(changed.manualValue(.opacity, at: 2 + Double(index) / 100))) }
        changed.setBaseValue(100, for: .opacity)
        var ids = Set<UUID>()
        try changed.validateAnimation(ids: &ids)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(changed)), changed)
        XCTAssertEqual(VisualClip(assetID: UUID(), start: 0, end: 1).baseValue(.opacity), 100)
        XCTAssertFalse(ImageParameter.opacity.accepts(-1)); XCTAssertFalse(ImageParameter.opacity.accepts(101))
        try performAutomationMenu(field, title: "オートメーションを削除")
        XCTAssertFalse(field.hasAutomation)
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.opacity), 50)
    }

    func testUniformPulseAndWavePeriodPersistenceAndSampling() throws {
        var curve = ImageCurve(parameter: .x)
        curve.minimum = -100; curve.maximum = 100
        curve.keys = [ImageKeyframe(time: 0, value: -50), ImageKeyframe(time: 2, value: 50, interpolation: .pulse)]
        let first = curve.keys[0].id
        XCTAssertEqual(curve.keys[1].resolvedPulseCycles, 4)
        for cycles in 1...20 {
            curve.keys[1].pulseCycles = cycles
            let width = 2 / Double(cycles * 2)
            let transitions = curve.keys[1].pulseTransitions.map { $0.fraction * 2 }
            let edges = [0.0] + transitions + [2.0]
            for (index, pair) in zip(edges, edges.dropFirst()).enumerated() {
                XCTAssertEqual(pair.1 - pair.0, width, accuracy: 1e-10)
                XCTAssertEqual(curve.value(at: (pair.0 + pair.1) / 2), index % 2 == 0 ? -50 : 50)
            }
            let samples = curve.plotSamples(from: 0, through: 2, steps: 1)
            for time in transitions {
                XCTAssertEqual(samples.filter { $0.time == time }.count, 2)
            }
            XCTAssertEqual(curve.value(at: 0), -50)
            XCTAssertEqual(curve.value(at: 2), 50)
        }
        curve.adjustMidpoint(after: first, handleValue: 100)
        XCTAssertEqual(curve.keys[1].resolvedPulseCycles, 1)
        XCTAssertEqual(curve.keys[1].resolvedPulsePeriod, 1)
        curve.adjustMidpoint(after: first, handleValue: -100)
        XCTAssertEqual(curve.keys[1].resolvedPulseCycles, 20)
        XCTAssertEqual(curve.keys[1].resolvedPulsePeriod, 0.05, accuracy: 1e-10)
        let pulseCopy = try JSONDecoder().decode(ImageCurve.self, from: JSONEncoder().encode(curve))
        XCTAssertEqual(pulseCopy, curve)
        XCTAssertEqual(pulseCopy.keys[1].resolvedPulseCycles, 20)
        let label = try XCTUnwrap(curve.midpointLabel(after: first))
        XCTAssertTrue(label.contains("幅 0.050秒")); XCTAssertTrue(label.contains("周期 0.100秒"))
        curve.keys[1].interpolation = .wave
        XCTAssertEqual(curve.value(at: 0), -50)
        XCTAssertEqual(curve.value(at: 0.5), 0, accuracy: 1e-8)
        XCTAssertEqual(curve.value(at: 1), 50, accuracy: 1e-8)
        XCTAssertEqual(curve.value(at: 1.99999), -50, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 2), 50)
        let handle = try XCTUnwrap(curve.midpoint(after: first))
        curve.adjustMidpoint(after: first, handleValue: handle.value + 10)
        XCTAssertGreaterThan(curve.keys[1].resolvedWavePeriod, 1)
        curve.adjustMidpoint(after: first, handleValue: -100)
        XCTAssertEqual(curve.keys[1].resolvedWavePeriod, 0.05, accuracy: 1e-10)
        XCTAssertGreaterThan(curve.plotSamples(from: 0, through: 2, steps: 1).count, 600)
        curve.adjustMidpoint(after: first, handleValue: 100)
        XCTAssertEqual(curve.keys[1].resolvedWavePeriod, 2, accuracy: 1e-10)
        let decoded = try JSONDecoder().decode(ImageCurve.self, from: JSONEncoder().encode(curve))
        XCTAssertEqual(decoded, curve)
        var ids = Set<UUID>()
        try decoded.validate(ids: &ids)
        curve.keys[1].wavePeriod = .nan
        ids.removeAll()
        XCTAssertThrowsError(try curve.validate(ids: &ids))
    }

    @MainActor func testOscillatorHandlesPreviewCancelAndCommit() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = timeline
        defer { window.close() }
        timeline.visualMode = true; timeline.isEnabled = true; timeline.duration = 10; timeline.currentTime = 4
        var previews = [VisualTrack]()
        var commits = [VisualTrack]()
        timeline.onImagePreview = { previews.append($0) }
        timeline.onImageCommit = { value, _ in commits.append(value); timeline.visuals = value }
        defer { timeline.onImageCommit = nil }
        for mode in [ImageInterpolation.pulse, .wave] {
            var (track, clip) = try fixture()
            let first = clip.setKey(.x, at: 1, value: -50)
            _ = clip.setKey(.x, at: 3, value: 50)
            var curve = try XCTUnwrap(clip.curve(.x)); curve.minimum = -100; curve.maximum = 100
            curve.keys[1].interpolation = mode
            clip.setCurve(curve)
            track = try track.updating(clip, slot: 3, duration: 10)
            timeline.visuals = track; timeline.selectedImageID = clip.id; timeline.selectedSlot = 3
            timeline.revealAutomation(in: 3); timeline.selectGraph(.x, reveal: true)
            let midpoint = try XCTUnwrap(curve.midpoint(after: first))
            let y = 152 - (midpoint.value + 100) / 200 * 54
            func event(_ type: NSEvent.EventType, _ offset: Double) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: timeline.convert(NSPoint(x: timeline.x(at: 2), y: y + offset), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let count = commits.count
            timeline.mouseDown(with: event(.leftMouseDown, 0))
            timeline.mouseDragged(with: event(.leftMouseDragged, -5))
            XCTAssertEqual(timeline.visuals, track)
            let preview = try XCTUnwrap(previews.last?.clip(clip.id)?.curve(.x)?.keys.last)
            if mode == .pulse {
                XCTAssertLessThan(preview.resolvedPulseCycles, 4)
                XCTAssertGreaterThan(preview.resolvedPulsePeriod, 0.25)
            }
            else { XCTAssertGreaterThan(preview.resolvedWavePeriod, 1) }
            timeline.cancelDrag()
            XCTAssertEqual(previews.last, track)
            XCTAssertEqual(commits.count, count)
            timeline.mouseDown(with: event(.leftMouseDown, 0))
            timeline.mouseDragged(with: event(.leftMouseDragged, -4))
            timeline.mouseUp(with: event(.leftMouseUp, -6))
            XCTAssertEqual(commits.count, count + 1)
            let updated = try XCTUnwrap(commits.last?.clip(clip.id)?.curve(.x))
            XCTAssertEqual(updated.keys.map(\.time), curve.keys.map(\.time))
            XCTAssertEqual(updated.keys.map(\.value), curve.keys.map(\.value))
            XCTAssertEqual(updated.keys.last?.incomingInterpolation, mode)
            XCTAssertEqual(timeline.currentTime, 4)
            let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-" + mode.rawValue + ".png"))
            if mode == .pulse {
                timeline.visuals = track
                timeline.mouseDown(with: event(.leftMouseDown, 0))
                timeline.mouseDragged(with: event(.leftMouseDragged, 8))
                timeline.mouseUp(with: event(.leftMouseUp, 10))
                let lower = try XCTUnwrap(commits.last?.clip(clip.id)?.curve(.x)?.keys.last)
                XCTAssertGreaterThan(lower.resolvedPulseCycles, 4)
                XCTAssertLessThan(lower.resolvedPulsePeriod, 0.25)
                XCTAssertGreaterThan(lower.pulseTransitions.count, 2)
                timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-pulse-repeat.png"))
            }
        }
    }

    func testIncomingInterpolationModesAndHoldPlot() throws {
        var (_, clip) = try fixture()
        _ = clip.setKey(.x, at: 1, value: 0)
        let middle = clip.setKey(.x, at: 3, value: 100)
        _ = clip.setKey(.x, at: 5, value: 0)
        var curve = try XCTUnwrap(clip.curve(.x))
        XCTAssertTrue(curve.keys.allSatisfy { $0.incomingInterpolation == .single })
        XCTAssertEqual(curve.value(at: 0.5), 25)
        curve.keys[1].interpolation = .smooth
        XCTAssertEqual(curve.value(at: 0), 0)
        XCTAssertEqual(curve.value(at: 0.5), 15.625)
        XCTAssertEqual(curve.value(at: 1), 50)
        XCTAssertEqual(curve.value(at: 1.5), 84.375)
        XCTAssertEqual(curve.value(at: 2), 100)
        XCTAssertEqual(curve.value(at: 2.5), 75, "後ろの区間はシングル曲線のまま")
        XCTAssertLessThan(curve.value(at: 0.001), 0.001)
        XCTAssertLessThan(100 - curve.value(at: 1.999), 0.001)
        curve.keys[1].interpolation = .hold
        XCTAssertEqual(curve.value(at: 1.99999999), 0)
        XCTAssertEqual(curve.value(at: 2), 100)
        XCTAssertEqual(curve.value(at: 2.5), 75)
        XCTAssertNil(curve.midpoint(after: curve.keys[0].id))
        let samples = curve.plotSamples(from: 0, through: 4, steps: 100)
        XCTAssertEqual(samples.filter { $0.time == 2 }.map(\.value), [0, 100])
        XCTAssertEqual(curve.plotSamples(from: 2, through: 4, steps: 100).first?.value, 100)
        clip.setCurve(curve)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        clip.trimStart(to: 1.25)
        XCTAssertEqual(clip.manualValue(.x, at: 2.99), 0)
        XCTAssertEqual(clip.manualValue(.x, at: 3), 100)
        XCTAssertEqual(clip.curve(.x)?.keys.first(where: { $0.id == middle })?.incomingInterpolation, .hold)
    }

    @MainActor func testKeyContextMenuChangesIncomingCurveAndDeletesWithoutSeeking() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = timeline
        defer { window.close() }
        var (track, clip) = try fixture()
        _ = clip.setKey(.x, at: 1, value: -50)
        let target = clip.setKey(.x, at: 3, value: 50)
        _ = clip.setKey(.x, at: 5, value: -50)
        var curve = try XCTUnwrap(clip.curve(.x)); curve.minimum = -100; curve.maximum = 100
        clip.setCurve(curve)
        clip.end = 6
        track = try track.updating(clip, slot: 3, duration: 10)
        timeline.visualMode = true; timeline.isEnabled = true; timeline.duration = 10
        timeline.visuals = track; timeline.currentTime = 4
        timeline.revealAutomation(in: 3)
        var commits = 0
        var seeks = [Double]()
        timeline.onSeek = { seeks.append($0) }
        timeline.onImageCommit = { value, _ in commits += 1; timeline.visuals = value }
        defer { timeline.onImageCommit = nil }
        func menu(time: Double = 3, y: Double = 111.5) throws -> NSMenu {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                location: timeline.convert(NSPoint(x: timeline.x(at: time), y: y), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return try XCTUnwrap(timeline.menu(for: event))
        }
        func perform(_ title: String, in menu: NSMenu) throws {
            let item = try XCTUnwrap(menu.item(withTitle: title))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        let initial = try menu()
        XCTAssertEqual(initial.items.filter { !$0.isSeparatorItem }.map(\.title), ["削除", "シングル曲線", "スムーズ", "ホールド", "パルス", "ウェーブ"])
        XCTAssertEqual(initial.item(withTitle: "シングル曲線")?.state, .on)
        XCTAssertEqual(timeline.selectedKeyID, target)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(seeks, [])
        try perform("スムーズ", in: initial)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.manualValue(.x, at: 1.5), -34.375)
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.manualValue(.x, at: 3.5), 25)
        XCTAssertEqual(try menu().item(withTitle: "スムーズ")?.state, .on)
        func snapshot(_ name: String) throws {
            let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-interpolation-" + name + ".png"))
        }
        try snapshot("smooth")
        try perform("ホールド", in: menu())
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.manualValue(.x, at: 2.999), -50)
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.manualValue(.x, at: 3), 50)
        try snapshot("hold")
        try perform("パルス", in: menu())
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.curve(.x)?.keys[1].incomingInterpolation, .pulse)
        XCTAssertEqual(try menu().item(withTitle: "パルス")?.state, .on)
        try perform("ウェーブ", in: menu())
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.curve(.x)?.keys[1].incomingInterpolation, .wave)
        XCTAssertEqual(try menu().item(withTitle: "ウェーブ")?.state, .on)
        try perform("シングル曲線", in: menu())
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.manualValue(.x, at: 1.5), -25)
        XCTAssertEqual(commits, 5)
        try perform("削除", in: menu())
        XCTAssertEqual(commits, 6)
        XCTAssertEqual(timeline.visuals.clip(clip.id)?.curve(.x)?.keys.count, 2)
        XCTAssertFalse(timeline.visuals.clip(clip.id)?.curve(.x)?.keys.contains { $0.id == target } ?? true)
        XCTAssertEqual(seeks, [])
        XCTAssertEqual(timeline.currentTime, 4)
    }

    func testBendInterpolationPersistenceAndTrim() throws {
        var (_, clip) = try fixture()
        let first = clip.setKey(.x, at: 1, value: 0)
        _ = clip.setKey(.x, at: 3, value: 100)
        var curve = try XCTUnwrap(clip.curve(.x))
        curve.adjustMidpoint(after: first, handleValue: 90)
        XCTAssertEqual(curve.value(at: 0), 0)
        XCTAssertEqual(curve.value(at: 0.5), 55, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 1), 90, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 2), 100)
        curve.adjustMidpoint(after: first, handleValue: 10)
        XCTAssertEqual(curve.value(at: 1), 10, accuracy: 1e-9)
        XCTAssertEqual(curve.keys.map(\.value), [0, 100])
        clip.setCurve(curve)
        let data = try JSONEncoder().encode(clip)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: data), clip)
        let before = clip.manualValue(.x, at: 2)
        clip.trimStart(to: 1.25)
        XCTAssertEqual(clip.manualValue(.x, at: 2), before, accuracy: 1e-9)
        clip.setBaseValue(20, for: .x)
        XCTAssertEqual(clip.manualValue(.x, at: 2), before + 20, accuracy: 1e-9)
        curve.adjustMidpoint(after: first, handleValue: 50)
        XCTAssertNil(curve.keys.first?.midpointOffset)
        let legacyKey = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"time\":0,\"value\":5}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ImageKeyframe.self, from: legacyKey).midpointOffset)
        curve.keys[0].midpointOffset = .infinity
        var ids = Set<UUID>()
        XCTAssertThrowsError(try curve.validate(ids: &ids))

        var effectCurve = ImageCurve(parameter: .blurRadius)
        effectCurve.keys = [ImageKeyframe(time: 0, value: 0), ImageKeyframe(time: 2, value: 64)]
        effectCurve.adjustMidpoint(after: effectCurve.keys[0].id, handleValue: 64)
        for i in 0...100 { XCTAssertTrue((0...64).contains(effectCurve.value(at: Double(i) / 50))) }
    }

    @MainActor func testMidpointHandlePreviewCommitAndCancel() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = timeline
        defer { window.close() }
        var (track, clip) = try fixture()
        let first = clip.setKey(.x, at: 1, value: 0)
        _ = clip.setKey(.x, at: 3, value: 0)
        var curve = try XCTUnwrap(clip.curve(.x))
        curve.minimum = -100; curve.maximum = 100
        clip.setCurve(curve)
        track = try track.updating(clip, slot: 3, duration: 10)
        timeline.visualMode = true
        timeline.isEnabled = true
        timeline.duration = 10
        timeline.visuals = track
        timeline.selectedImageID = clip.id
        timeline.selectedSlot = 3
        timeline.currentTime = 4
        timeline.revealAutomation(in: 3)
        timeline.selectGraph(.x, reveal: true)
        var previews = [VisualTrack]()
        var commits = [VisualTrack]()
        var seeks = [Double]()
        timeline.onImagePreview = { previews.append($0) }
        timeline.onImageCommit = { value, _ in commits.append(value); timeline.visuals = value }
        timeline.onSeek = { seeks.append($0) }
        defer { timeline.onImageCommit = nil }
        func event(_ type: NSEvent.EventType, y: Double, time: Double = 2) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(NSPoint(x: timeline.x(at: time), y: y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        timeline.mouseMoved(with: event(.mouseMoved, y: 125))
        timeline.mouseDown(with: event(.leftMouseDown, y: 125))
        timeline.mouseDragged(with: event(.leftMouseDragged, y: 112))
        XCTAssertEqual(timeline.visuals, track)
        XCTAssertGreaterThan(try XCTUnwrap(previews.last?.clip(clip.id)?.manualValue(.x, at: 2)), 0)
        timeline.mouseUp(with: event(.leftMouseUp, y: 105))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(seeks, [])
        let updated = try XCTUnwrap(commits.last?.clip(clip.id)?.curve(.x))
        XCTAssertEqual(updated.keys.map(\.time), curve.keys.map(\.time))
        XCTAssertEqual(updated.keys.map(\.value), [0, 0])
        XCTAssertGreaterThan(try XCTUnwrap(updated.keys.first?.midpointOffset), 0)
        XCTAssertEqual(updated.keys.count, 2)
        let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
        timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/my_movie-curve-handles-preview.png"))
        timeline.mouseDown(with: event(.leftMouseDown, y: 105))
        timeline.mouseDragged(with: event(.leftMouseDragged, y: 140))
        XCTAssertLessThan(try XCTUnwrap(previews.last?.clip(clip.id)?.manualValue(.x, at: 2)), 0)
        timeline.cancelDrag()
        XCTAssertEqual(previews.last, commits.last)
        XCTAssertEqual(commits.count, 1)
        timeline.mouseDown(with: event(.leftMouseDown, y: 105))
        timeline.mouseDragged(with: event(.leftMouseDragged, y: 140))
        timeline.mouseUp(with: event(.leftMouseUp, y: 145))
        XCTAssertEqual(commits.count, 2)
        XCTAssertLessThan(try XCTUnwrap(commits.last?.clip(clip.id)?.curve(.x)?.midpoint(after: first)?.value), 0)
        XCTAssertEqual(timeline.currentTime, 4)
    }

    func testInterpolationPulseAndTrimmingPreserveTheCurve() throws {
        var (track, clip) = try fixture()
        clip.audioModulations[.scale]?.source = .beat
        let first = clip.setKey(.scale, at: 1, value: 100)
        let last = clip.setKey(.scale, at: 3, value: 140)
        XCTAssertEqual(clip.setKey(.scale, at: 3 + 1e-8, value: 140), last)
        _ = clip.setKey(.rotation, at: 1, value: 0)
        _ = clip.setKey(.rotation, at: 3, value: 360)
        let settings = SceneSettings(bpm: 120, beatOffset: 1.5, spectrum: false)
        XCTAssertEqual((ParameterEvaluator.value(.scale, clip: clip, at: 2, settings: settings, features: nil) / 100), 1.296, accuracy: 1e-9)
        XCTAssertEqual(clip.manualValue(.rotation, at: 2), 180)
        XCTAssertEqual((ParameterEvaluator.value(.scale, clip: clip, at: 1.25, settings: settings, features: nil) / 100), 1.05, accuracy: 1e-9)
        XCTAssertEqual(clip.keyTime(at: 1.01, grid: TimelineSnapGrid(bpm: 137, origin: 0.1)), 1)
        XCTAssertEqual(clip.keyTime(at: 1.04, grid: nil), 1.04)

        track = try track.updating(clip, slot: 3, duration: 10)
        let trimmed = try track.dragging(id: clip.id, part: .start, delta: 0.5, duration: 10, grid: TimelineSnapGrid())
        let shortened = try XCTUnwrap(trimmed.clip(clip.id))
        XCTAssertEqual(shortened.curve(.scale)?.keys.first?.time, -0.5)
        XCTAssertEqual(shortened.manualValue(.scale, at: 1.75), 115, accuracy: 1e-9)
        let restored = try trimmed.dragging(id: clip.id, part: .start, delta: -0.5, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(restored, track)
        var shifted = shortened
        shifted.setBaseValue(45, for: .rotation)
        XCTAssertEqual(shifted.curve(.rotation)?.keys.map(\.time), [-0.5, 1.5])
        XCTAssertEqual(shifted.curve(.rotation)?.keys.map(\.value), [45, 405])
        XCTAssertEqual(shifted.curve(.rotation)?.minimum, -135)
        XCTAssertEqual(shifted.curve(.rotation)?.maximum, 225)
        let moved = try track.dragging(id: clip.id, part: .move, delta: 1, duration: 10, grid: TimelineSnapGrid())
        XCTAssertEqual(moved.clips[0].manualValue(.rotation, at: 3), 180)

        clip.removeKey(first, parameter: .scale)
        clip.removeKey(last, parameter: .scale)
        XCTAssertNil(clip.curve(.scale))
        XCTAssertEqual(clip.manualValue(.scale, at: 1), 140)
    }

    @MainActor private func control<T: NSControl>(_ id: String, in view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        return view.subviews.lazy.compactMap { self.control(id, in: $0) as T? }.first
    }

    @MainActor func testTransformFieldDoubleClickAndHorizontalDrag() throws {
        _ = NSApplication.shared
        let editor = VisualEditor()
        let window = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        defer { window.close() }
        let timeline = TimelineView(frame: .zero)
        editor.timeline = timeline
        let (track, clip) = try fixture()
        editor.duration = 10
        editor.load(track, projectURL: nil)
        editor.setAvailable(true)
        timeline.onImageSelect?(clip.id, 3)
        editor.currentTime = 2

        let field = try XCTUnwrap(control("visuals.value.scale", in: editor.view) as DragValueField?)
        func event(_ type: NSEvent.EventType, x: Double = 100, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: clicks, pressure: 1)!
        }
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseUp(with: event(.leftMouseUp))
        XCTAssertNil(field.currentEditor())
        field.mouseDown(with: event(.leftMouseDown, clicks: 2))
        XCTAssertNotNil(field.currentEditor())
        XCTAssertTrue(window.makeFirstResponder(nil))

        var previews = [VisualTrack]()
        var commits = 0
        editor.onPreview = { previews.append($0) }
        editor.onChange = { _ in commits += 1 }
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseDragged(with: event(.leftMouseDragged, x: 117))
        XCTAssertEqual(editor.track, track)
        XCTAssertEqual(previews.last?.clip(clip.id)?.fixedValues[.scale], 117)
        field.mouseUp(with: event(.leftMouseUp, x: 120))
        XCTAssertEqual(editor.track.clip(clip.id)?.fixedValues[.scale], 120)
        XCTAssertEqual(commits, 1)

        XCTAssertNil(control("visuals.key.scale", in: editor.view) as NSButton?)
        XCTAssertFalse(field.hasAutomation)
        try performAutomationMenu(field, title: "オートメーションを作成")
        XCTAssertTrue(field.hasAutomation)
        let bitmap = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/my_movie-automation-badge.png"))
        let keyed = editor.track
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseDragged(with: event(.leftMouseDragged, x: 110))
        XCTAssertTrue(editor.cancelValueDrag())
        field.mouseUp(with: event(.leftMouseUp, x: 110))
        XCTAssertEqual(editor.track, keyed)
        XCTAssertEqual(Double(field.stringValue), 120)
        field.mouseDown(with: event(.leftMouseDown))
        field.mouseDragged(with: event(.leftMouseDragged, x: 115))
        field.mouseUp(with: event(.leftMouseUp, x: 115))
        XCTAssertEqual(Double(field.stringValue), 135)
        let shifted = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertEqual(shifted.baseValue(.scale), 135)
        XCTAssertEqual(shifted.curve(.scale)?.keys.first?.value, 135)
        XCTAssertEqual(shifted.curve(.scale)?.minimum, 45)
        XCTAssertEqual(shifted.curve(.scale)?.maximum, 235)
        XCTAssertEqual(commits, 3)

        let minimum = try XCTUnwrap(control("visuals.graph.minimum", in: editor.view) as DragValueField?)
        let maximum = try XCTUnwrap(control("visuals.graph.maximum", in: editor.view) as DragValueField?)
        for bound in [minimum, maximum] {
            bound.mouseDown(with: event(.leftMouseDown))
            bound.mouseDragged(with: event(.leftMouseDragged, x: 110))
            bound.mouseUp(with: event(.leftMouseUp, x: 110))
        }
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 55)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.maximum, 245)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.value, 135)

        let middle = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                            mouseCursorPosition: .zero, mouseButton: .center))
        let reset = try XCTUnwrap(NSEvent(cgEvent: middle))
        field.otherMouseDown(with: reset)
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.scale), 100)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.value, 100)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 20)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.maximum, 210)
        maximum.mouseDown(with: event(.leftMouseDown))
        maximum.mouseDragged(with: event(.leftMouseDragged, x: 115))
        maximum.mouseUp(with: event(.leftMouseUp, x: 115))
        maximum.otherMouseDown(with: reset)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.maximum, 200)
        minimum.mouseDown(with: event(.leftMouseDown))
        minimum.mouseDragged(with: event(.leftMouseDragged, x: 105))
        minimum.mouseUp(with: event(.leftMouseUp, x: 105))
        minimum.otherMouseDown(with: reset)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 10)
        let automated = editor.track
        let commitsBeforeDelete = commits
        try performAutomationMenu(field, title: "オートメーションを削除")
        XCTAssertFalse(field.hasAutomation)
        XCTAssertNil(editor.track.clip(clip.id)?.curve(.scale))
        XCTAssertEqual(editor.track.clip(clip.id)?.baseValue(.scale), 100)
        XCTAssertEqual(commits, commitsBeforeDelete + 1)
        editor.load(automated, projectURL: nil)
        timeline.onImageSelect?(clip.id, 3)
        XCTAssertTrue(field.hasAutomation, "復元時に青い丸も復元する")
        editor.setAvailable(false)
        XCTAssertNil(automationMenu(field))
    }

    @MainActor func testInspectorAndGraphAddMoveCancelAndDelete() throws {
        _ = NSApplication.shared
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 1000, height: 210))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = timeline
        defer { window.close() }
        let editor = VisualEditor()
        _ = editor.view
        editor.timeline = timeline
        let grid = TimelineSnapGrid(division: .quarter)
        editor.snapGrid = grid
        timeline.snapGrid = grid
        let (track, clip) = try fixture()
        editor.duration = 10
        editor.load(track, projectURL: nil)
        editor.setAvailable(true)
        timeline.visualMode = true
        timeline.duration = 10
        timeline.onSeek = { time in timeline.currentTime = time; editor.currentTime = time }
        editor.onSeek = timeline.onSeek
        defer { timeline.onSeek = nil; editor.onSeek = nil }
        timeline.onImageSelect?(clip.id, 3)
        timeline.onSeek?(1.52)

        let value = try XCTUnwrap(control("visuals.value.scale", in: editor.view) as NSTextField?)
        let knob = try XCTUnwrap(value as? DragValueField)
        value.stringValue = "150"
        try performAutomationMenu(knob, title: "オートメーションを作成")
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.time, 0.5)
        XCTAssertTrue(timeline.expandedLayerSlots.contains(3))
        XCTAssertEqual(timeline.selectedParameter, .scale)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.first?.value, 150)
        let minimum = try XCTUnwrap(control("visuals.graph.minimum", in: editor.view) as NSTextField?)
        let maximum = try XCTUnwrap(control("visuals.graph.maximum", in: editor.view) as NSTextField?)
        minimum.stringValue = "50"; maximum.stringValue = "150"
        XCTAssertTrue(maximum.sendAction(maximum.action, to: maximum.target))
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.minimum, 50)
        XCTAssertEqual(editor.track.clip(clip.id)?.manualValue(.scale, at: 2), 150)

        func event(_ type: NSEvent.EventType, time: Double, y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(NSPoint(x: timeline.x(at: time), y: y), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        timeline.onSeek?(1.52)
        timeline.mouseDown(with: event(.leftMouseDown, time: 2.62, y: 125))
        timeline.mouseUp(with: event(.leftMouseUp, time: 2.62, y: 125))
        XCTAssertEqual(timeline.currentTime, 1.52, "点を追加しても再生ヘッドを移動しない")
        XCTAssertEqual(editor.currentTime, 1.52)
        let added = editor.track
        let key = try XCTUnwrap(added.clip(clip.id)?.curve(.scale)?.keys.last)
        XCTAssertEqual(key.time, 1.5)
        XCTAssertEqual(key.value, 100, accuracy: 1e-9)
        XCTAssertEqual(timeline.selectedKeyID, key.id)

        func hasYellowMarker() throws -> Bool {
            let bitmap = try XCTUnwrap(timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds))
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            let scale = Double(bitmap.pixelsWide) / timeline.bounds.width
            let x = Int((timeline.x(at: 2.5) + 4.5) * scale)
            return (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.75 && color.greenComponent > 0.6 && color.blueComponent < 0.5
            }
        }
        timeline.mouseMoved(with: event(.mouseMoved, time: 2.5, y: 134))
        XCTAssertTrue(try hasYellowMarker(), "当たり判定内では通常のマーカーより外側まで黄色で表示する")
        timeline.mouseMoved(with: event(.mouseMoved, time: 2.5, y: 141))
        XCTAssertFalse(try hasYellowMarker())
        timeline.mouseDown(with: event(.leftMouseDown, time: 2.5, y: 134))
        XCTAssertEqual(timeline.selectedKeyID, key.id, "点の中心から9pt離れていても掴める")
        XCTAssertEqual(timeline.currentTime, 2.5, "既存の点を選ぶとその時刻に移動する")
        timeline.mouseDragged(with: event(.leftMouseDragged, time: 2.85, y: 121))
        XCTAssertEqual(editor.track, added)
        timeline.cancelDrag()
        XCTAssertEqual(editor.track, added)
        timeline.mouseDown(with: event(.leftMouseDown, time: 2.5, y: 134))
        timeline.mouseDragged(with: event(.leftMouseDragged, time: 2.85, y: 121))
        timeline.mouseUp(with: event(.leftMouseUp, time: 2.85, y: 121))
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.last?.time, 2)
        XCTAssertEqual(timeline.selectedKeyID, key.id)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                      charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        timeline.keyDown(with: delete)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.count, 1)
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil),
                                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { timeline.mouseDown(with: event) } else { timeline.mouseUp(with: event) }
            }
        }
        click(NSPoint(x: timeline.x(at: 4), y: 69))
        XCTAssertNil(timeline.selectedImageID)
        XCTAssertTrue(timeline.expandedLayerSlots.contains(3), "空白をクリックしてもレーンを収納しない")
        click(NSPoint(x: 65, y: 69))
        XCTAssertFalse(timeline.expandedLayerSlots.contains(3))
        click(NSPoint(x: 65, y: 69))
        XCTAssertTrue(timeline.expandedLayerSlots.contains(3))
        click(NSPoint(x: timeline.x(at: 1.5), y: 98))
        XCTAssertEqual(timeline.selectedImageID, clip.id, "レーンからクリップを再選択できる")
        let snap = try XCTUnwrap(control("visuals.keySnap", in: editor.view) as NSButton?)
        snap.performClick(nil)
        timeline.onSeek?(2.123)
        click(NSPoint(x: timeline.x(at: 2.123), y: 125))
        let freeKey = try XCTUnwrap(editor.track.clip(clip.id)?.curve(.scale)?.keys.last)
        XCTAssertEqual(freeKey.time, 1.123, accuracy: 1e-9)
        snap.performClick(nil)
        click(NSPoint(x: timeline.x(at: 2.123), y: 125))
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.count, 2)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.last?.id, freeKey.id)
        XCTAssertEqual(editor.track.clip(clip.id)?.curve(.scale)?.keys.last?.value, freeKey.value)
        XCTAssertEqual(Double(value.stringValue), 150)

        func contextMenu(at point: NSPoint) -> NSMenu? {
            let click = NSEvent.mouseEvent(with: .rightMouseDown, location: timeline.convert(point, to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return timeline.menu(for: click)
        }
        let original = editor.track
        XCTAssertNil(contextMenu(at: NSPoint(x: timeline.x(at: 2), y: 105)))
        let menu = try XCTUnwrap(contextMenu(at: NSPoint(x: 20, y: 105)))
        let removal = try XCTUnwrap(menu.item(withTitle: "レーンを削除（キーと音楽同期）"))
        XCTAssertEqual(editor.track, original)
        var commits = 0
        editor.onChange = { _ in commits += 1 }
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(removal.action), to: removal.target, from: removal))
        XCTAssertEqual(commits, 1)
        let updated = try XCTUnwrap(editor.track.clip(clip.id))
        XCTAssertNil(updated.curve(.scale))
        XCTAssertFalse(knob.hasAutomation, "レーンから削除してもノブの表示を更新する")
        XCTAssertEqual(updated.manualValue(.scale, at: 2), 150)
        XCTAssertNil(timeline.selectedParameter)
        XCTAssertNil(timeline.selectedKeyID)
        XCTAssertEqual(timeline.currentTime, 2.123)
        XCTAssertNil(contextMenu(at: NSPoint(x: 20, y: 105)))
    }
}
