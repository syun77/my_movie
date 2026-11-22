import AppKit
import AVFoundation
import XCTest
@testable import MVStudio

final class LFOAutomationTests: XCTestCase {
    private func clip(_ parameter: ImageParameter = .scale, settings: LFOSettings = LFOSettings()) -> VisualClip {
        var clip = VisualClip(start: 1, end: 10)
        clip.setAutomation(ParameterAutomation(parameter: parameter, mode: .lfo, lfo: settings))
        return clip
    }
    func testWaveShapesTiltCurveAndBipolar() {
        var lfo = LFOSettings()
        for (phase, expected) in [(0.0,-1.0),(0.25,0),(0.5,1),(0.75,0),(1,-1),(-0.25,0)] {
            XCTAssertEqual(LFOEvaluator.signal(phase: phase, settings: lfo), expected, accuracy: 1e-12)
        }
        lfo.bipolar = false; lfo.tilt = 100
        XCTAssertEqual(LFOEvaluator.signal(phase: 0.25, settings: lfo), 0.25)
        lfo.tilt = -100
        XCTAssertEqual(LFOEvaluator.signal(phase: 0.25, settings: lfo), 0.75)
        lfo.tilt = 0; lfo.curve = 100
        XCTAssertEqual(LFOEvaluator.signal(phase: 0.125, settings: lfo), (1-cos(.pi/4))/2, accuracy: 1e-12)
        lfo.curve = -100
        for (phase, expected) in [(0.0,0.0),(0.25,1),(0.749999,1),(0.75,0),(1,0)] {
            XCTAssertEqual(LFOEvaluator.signal(phase: phase, settings: lfo), expected)
        }
        lfo.curve = -99.999999
        for phase in [0.0,0.01,0.249,0.25,0.251,0.5,0.75,0.99] {
            let value = LFOEvaluator.signal(phase: phase, settings: lfo)
            XCTAssertTrue(value.isFinite && (0...1).contains(value))
        }
    }
    func testTimingHzBeatChoicesNegativeOriginAndSeeking() {
        var lfo = LFOSettings(); lfo.amount = 20
        let scene = SceneSettings(bpm: 137.3, beatOffset: 0.7)
        for choice in LFOSettings.BeatPeriod.choices {
            lfo.beatsPerCycle = choice.period
            XCTAssertTrue(lfo.isValid(for: .scale))
            let period = 60 * choice.period.value / scene.bpm
            for time in [-0.2,0.7,1.234,36000.0] {
                let a = LFOEvaluator.value(base: 100, at: time, clipStart: 1, settings: lfo, scene: scene)
                let b = LFOEvaluator.value(base: 100, at: time+period, clipStart: 1, settings: lfo, scene: scene)
                XCTAssertEqual(a,b,accuracy:1e-7)
            }
        }
        lfo.timebase = .hertz; lfo.frequencyHz = 2; lfo.phaseOrigin = .clip
        let a = LFOEvaluator.value(base: 100, at: 1.125, clipStart: 1, settings: lfo, scene: scene)
        XCTAssertEqual(a,100)
        XCTAssertEqual(a,LFOEvaluator.value(base: 100, at: 1.125, clipStart: 1, settings: lfo, scene: SceneSettings(bpm: 280)))
        lfo.phaseDegrees = 180
        XCTAssertEqual(LFOEvaluator.value(base: 100, at: 1, clipStart: 1, settings: lfo, scene: scene),120)
    }
    func testModeSwitchKeepsKeysAndBaseShiftsWithoutChangingAmount() throws {
        var clip = VisualClip(start: 1, end: 10)
        let first = clip.setKey(.scale, at: 1, value: 100)
        _ = clip.setKey(.scale, at: 3, value: 140)
        clip.setAutomationMode(.lfo, for: .scale)
        var item = try XCTUnwrap(clip.automation(.scale)); item.lfo?.amount = 20; clip.setAutomation(item)
        XCTAssertEqual(clip.displayCurve(.scale)?.keys.count,0)
        XCTAssertEqual(clip.curve(.scale)?.keys.count,2)
        XCTAssertEqual(ParameterEvaluator.value(.scale,clip:clip,at:2,settings:SceneSettings(),features:nil),80)
        clip.setBaseValue(110,for:.scale)
        XCTAssertEqual(clip.curve(.scale)?.keys.map(\.value),[110,150])
        XCTAssertEqual(clip.activeLFO(.scale)?.amount,20)
        clip.setAutomationMode(.keys, for: .scale)
        XCTAssertEqual(ParameterEvaluator.value(.scale,clip:clip,at:2,settings:SceneSettings(),features:nil),130)
        XCTAssertEqual(clip.displayCurve(.scale)?.keys.first?.id,first)
        let before = ParameterEvaluator.value(.scale,clip:clip,at:2,settings:SceneSettings(),features:nil)
        clip.automationRanges[.scale] = .init(lower: 10,upper: 20)
        XCTAssertEqual(ParameterEvaluator.value(.scale,clip:clip,at:2,settings:SceneSettings(),features:nil),before)
        var ids=Set<UUID>(); try clip.validateAnimation(ids:&ids)
    }
    func testCompositionLimitsCountsAndNoPrematureClamping() throws {
        var lfo = LFOSettings(); lfo.amount = 20; lfo.timebase = .hertz
        var c = clip(.opacity,settings:lfo)
        XCTAssertEqual(ParameterEvaluator.value(.opacity,clip:c,at:0.5,settings:SceneSettings(),features:nil),100)
        c.audioModulations[.opacity] = AudioModulation(source:.beat,amount:-10)
        XCTAssertEqual(ParameterEvaluator.value(.opacity,clip:c,at:0.5,settings:SceneSettings(),features:nil),100)
        c.audioModulations[.opacity]?.amount = -30
        XCTAssertEqual(ParameterEvaluator.value(.opacity,clip:c,at:0.5,settings:SceneSettings(),features:nil),90)
        c = clip(.scale,settings:lfo)
        c.audioModulations[.scale] = AudioModulation(source:.beat,blend:.relative,amount:10)
        XCTAssertEqual(ParameterEvaluator.value(.scale,clip:c,at:0.5,settings:SceneSettings(),features:nil),132,accuracy:1e-10)
        lfo.amount=1.6
        c = VisualClip(start:0,end:5,effects:ImageEffects(particles:.init(seed:1)))
        c.setAutomation(.init(parameter:.particlesCount,mode:.lfo,lfo:lfo))
        let base = c.baseValue(.particlesCount)
        XCTAssertEqual(c.evaluatedEffects(at:0.5)?.particles?.count,(base+1.6).rounded())
        var ids=Set<UUID>(); try c.validateAnimation(ids:&ids)
    }
    func testTrimMovePersistenceAndNodeOwnership() throws {
        var lfo=LFOSettings(); lfo.amount=20; lfo.phaseOrigin = .clip; lfo.timebase = .hertz
        var c=clip(settings:lfo)
        _ = c.setKey(.scale,at:2,value:130)
        let before=ParameterEvaluator.value(.scale,clip:c,at:3.125,settings:SceneSettings(),features:nil)
        c.trimStart(to:2.1)
        XCTAssertEqual(ParameterEvaluator.value(.scale,clip:c,at:3.125,settings:SceneSettings(),features:nil),before,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(c.activeLFO(.scale)).clockOffsetSeconds,1.1,accuracy:1e-10)
        c.start += 2; c.end += 2
        XCTAssertEqual(ParameterEvaluator.value(.scale,clip:c,at:5.125,settings:SceneSettings(),features:nil),before,accuracy:1e-10)
        c.effects=ImageEffects(blur:.init(),particles:.init(seed:1))
        c.setAutomation(.init(parameter:.blurRadius,mode:.lfo,lfo:lfo))
        XCTAssertEqual(c.effects?.node(for:.blurRadius)?.automations.count,1)
        let encoded=try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self,from:encoded),c)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNil(json["curves"])
        c.effects?.blur=nil
        XCTAssertNil(c.activeLFO(.blurRadius)); XCTAssertNotNil(c.activeLFO(.scale))
        c.removeAudioAndKeys(.scale); XCTAssertNil(c.displayCurve(.scale))
    }
    func testEmitterRemappingAndDeletingLastDormantKey() throws {
        var c=VisualClip(start:0,end:5,effects:ImageEffects(particles:.init(seed:1)))
        c.effects?.particles?.emitters.append(.init())
        c.setAutomationMode(.lfo,for:.emitter1X)
        c.removeEmitterAutomation(at:0)
        XCTAssertNotNil(c.activeLFO(.emitter0X)); XCTAssertNil(c.automation(.emitter1X))
        let id=c.setKey(.scale,at:1,value:120)
        c.setAutomationMode(.lfo,for:.scale)
        c.removeKey(id,parameter:.scale)
        XCTAssertNotNil(c.activeLFO(.scale)); XCTAssertNil(c.curve(.scale))
        c.setAutomationMode(.keys,for:.scale)
        XCTAssertEqual(c.manualValue(.scale,at:2),120)
        var ids=Set<UUID>(); try c.validateAnimation(ids:&ids)
    }
    func testPlotSamplesJumpsAndBoundedDenseLongRange() {
        var lfo=LFOSettings(); lfo.timebase = .hertz; lfo.curve = -100
        let scene=SceneSettings()
        let points=LFOEvaluator.samples(from:0,through:2,pixels:400,clipStart:0,settings:lfo,scene:scene)
        for time in [0.25,0.75,1.25,1.75] {
            let jump=points.filter { abs($0.0-time)<1e-12 }
            XCTAssertTrue(jump.contains { $0.1 == -1 }); XCTAssertTrue(jump.contains { $0.1 == 1 })
        }
        lfo.curve = -99.99; lfo.tilt=99.99
        let sharp=LFOEvaluator.samples(from:0,through:2,pixels:400,clipStart:0,settings:lfo,scene:scene)
        XCTAssertLessThanOrEqual(sharp.count,8200)
        lfo.frequencyHz=20
        let dense=LFOEvaluator.samples(from:0,through:300,pixels:1000,clipStart:0,settings:lfo,scene:scene)
        XCTAssertEqual(dense.count,4)
        XCTAssertEqual(dense.map(\.1).min(),-1); XCTAssertEqual(dense.map(\.1).max(),1)
    }
    func testProjectRoundTripAndDenseModulationBudget() throws {
        var lfo = LFOSettings(); lfo.timebase = .hertz; lfo.frequencyHz = 0.01; lfo.amount = 20
        var c = clip(settings: lfo)
        _ = c.setKey(.scale, at: 2, value: 130)
        c.audioModulations[.scale] = AudioModulation(source: .beat, amount: 10)
        c.audioModulations[.scale]?.beatNoteDenominator = 16
        let plot = ParameterEvaluator.lfoPlot(.scale, clip: c, from: 0, through: 300, pixels: 1000,
                                               settings: SceneSettings(bpm: 300), features: nil)
        XCTAssertTrue(plot.isEnvelope); XCTAssertEqual(plot.samples.count, 4)
        XCTAssertLessThanOrEqual(plot.samples.map(\.1).min()!, 80)
        XCTAssertGreaterThanOrEqual(plot.samples.map(\.1).max()!, 130)
        var track = VisualTrack(); track.layers[0].clips = [c]
        let url = URL(fileURLWithPath: "/tmp/lfo.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/tone.wav"), visuals: track,
                                  settings: SceneSettings(), projectURL: url)
        let restored = try ProjectMigrator.read(JSONEncoder().encode(project), at: url)
        XCTAssertFalse(restored.needsMigration); XCTAssertEqual(restored.project.visuals, track)
        c.fixedValues[.scale] = Double.greatestFiniteMagnitude
        c.audioModulations[.scale]?.blend = .relative
        var ids = Set<UUID>(); XCTAssertThrowsError(try c.validateAnimation(ids: &ids))
    }

    @MainActor func testCopyRenewsDormantKeyIDsAndKeepsLFOClock() throws {
        _ = NSApplication.shared
        let editor = PlacementEditor(); _ = editor.view
        editor.duration = 10; editor.restoreTab(.visuals); editor.setAvailable(hasAudio: true, isBusy: false)
        var c = VisualClip(start: 1, end: 3, effects: ImageEffects(blur: .init()))
        let key = c.setKey(.blurRadius, at: 1, value: 10)
        var lfo = LFOSettings(); lfo.phaseOrigin = .clip; lfo.clockOffsetSeconds = 0.2; lfo.amount = 5
        c.setAutomation(.init(parameter: .blurRadius, mode: .lfo, keyCurve: c.automation(.blurRadius)?.keyCurve, lfo: lfo))
        var track = VisualTrack(); track.layers[0].clips = [c]
        editor.visuals.load(track, projectURL: URL(fileURLWithPath: "/tmp/lfo.mvproject"))
        editor.timeline.onImageSelect?(c.id, track.layers[0].id)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        editor.editClip(.copy, pasteboard: board); editor.currentTime = 5; editor.editClip(.paste, pasteboard: board)
        let pasted = try XCTUnwrap(editor.visuals.track.clips.last)
        XCTAssertEqual(pasted.start, 5); XCTAssertEqual(pasted.activeLFO(.blurRadius), lfo)
        XCTAssertNotEqual(pasted.curve(.blurRadius)?.keys.first?.id, key)
        XCTAssertNotEqual(pasted.effects?.nodes.first?.id, c.effects?.nodes.first?.id)
        try editor.visuals.track.validate(duration: 10)
    }

    func testInvalidSettingsAndSchemaInjection() throws {
        var c=clip()
        for value in [Double.nan,.infinity,-1,21] {
            var item=try XCTUnwrap(c.automation(.scale)); item.lfo?.frequencyHz=value; c.setAutomation(item)
            var ids=Set<UUID>(); XCTAssertThrowsError(try c.validateAnimation(ids:&ids))
        }
        c=clip(); var item=try XCTUnwrap(c.automation(.scale)); item.lfo?.beatsPerCycle.denominator=0; c.setAutomation(item)
        var ids=Set<UUID>(); XCTAssertThrowsError(try c.validateAnimation(ids:&ids))
        let path=try XCTUnwrap(Bundle.module.url(forResource:"v18",withExtension:"json",subdirectory:"Fixtures/Projects"))
        var root=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
        var layers=root["visualLayers"] as! [[String:Any]]; var clips=layers[0]["clips"] as! [[String:Any]]
        clips[0]["curves"]=[]; layers[0]["clips"]=clips; root["visualLayers"]=layers
        XCTAssertThrowsError(try ProjectMigrator.read(JSONSerialization.data(withJSONObject:root),at:URL(fileURLWithPath:"/tmp/lfo.mvproject")))
    }
    @MainActor func testInspectorDragCancelModeSwitchGraphSelectionAndHistory() throws {
        _ = NSApplication.shared
        let editor=VisualEditor(); _ = editor.view
        let timeline=TimelineView(frame:NSRect(x:0,y:0,width:1000,height:260))
        let window=NSWindow(contentRect:timeline.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=timeline; defer { window.close() }
        editor.timeline=timeline; editor.duration=10
        var c=VisualClip(start:1,end:9); _ = c.setKey(.scale,at:1,value:100); _ = c.setKey(.scale,at:3,value:120)
        var track=VisualTrack(); track.layers[0].clips=[c]
        editor.load(track,projectURL:nil); editor.setAvailable(true)
        timeline.visualMode=true; timeline.duration=10
        timeline.onImageSelect?(c.id,track.layers[0].id)
        timeline.currentTime=2.123; editor.currentTime=2.123
        func control<T:NSView>(_ name:String, _ type:T.Type) throws -> T {
            func find(_ view:NSView)->T? {
                if view.identifier?.rawValue==name { return view as? T }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return try XCTUnwrap(find(editor.view))
        }
        let mode=try control("lfo.mode",NSPopUpButton.self)
        let amount=try control("lfo.amount",DragValueField.self)
        XCTAssertTrue(amount.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(mode.isHiddenOrHasHiddenAncestor)
        let history=EditHistory(); history.reset(EditSnapshot(visuals:track))
        var commits=0, previews=0
        editor.onChange={ value in commits += 1; history.record(EditSnapshot(visuals:value)) }
        editor.onPreview={ _ in previews += 1 }
        mode.selectItem(at:1); XCTAssertTrue(mode.sendAction(mode.action,to:mode.target))
        XCTAssertNotNil(editor.track.clip(c.id)?.activeLFO(.scale))
        XCTAssertFalse(amount.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(commits,1)
        XCTAssertTrue(amount.onDragStart?() == true)
        amount.onDragChange?(20)
        XCTAssertEqual(commits,1); XCTAssertGreaterThan(previews,0)
        XCTAssertEqual(timeline.automationPreview?.clip(c.id)?.activeLFO(.scale)?.amount,20)
        amount.onDragEnd?()
        XCTAssertEqual(commits,2); XCTAssertEqual(editor.track.clip(c.id)?.activeLFO(.scale)?.amount,20)
        XCTAssertEqual(history.undo()?.visuals.clip(c.id)?.activeLFO(.scale)?.amount,0)
        XCTAssertEqual(history.redo()?.visuals.clip(c.id)?.activeLFO(.scale)?.amount,20)
        XCTAssertTrue(amount.onDragStart?() == true); amount.onDragChange?(10)
        XCTAssertTrue(amount.cancelNumberDrag()); XCTAssertNil(timeline.automationPreview)
        XCTAssertEqual(editor.track.clip(c.id)?.activeLFO(.scale)?.amount,20); XCTAssertEqual(commits,2)
        amount.onReset?(); XCTAssertEqual(editor.track.clip(c.id)?.activeLFO(.scale)?.amount,0)
        let phase=try control("lfo.phase",DragValueField.self)
        phase.stringValue="360"; XCTAssertTrue(phase.sendAction(phase.action,to:phase.target))
        XCTAssertEqual(editor.track.clip(c.id)?.activeLFO(.scale)?.phaseDegrees,0)
        timeline.revealAutomation(in:track.layers[0].id)
        let event=NSEvent.mouseEvent(with:.leftMouseDown,location:timeline.convert(NSPoint(x:timeline.x(at:2.5),y:125),to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        timeline.mouseDown(with:event); timeline.mouseUp(with:event)
        XCTAssertEqual(timeline.currentTime,2.123); XCTAssertEqual(editor.track.clip(c.id)?.curve(.scale)?.keys.count,2)
        mode.selectItem(at:0); XCTAssertTrue(mode.sendAction(mode.action,to:mode.target))
        XCTAssertEqual(editor.track.clip(c.id)?.displayCurve(.scale)?.keys.count,2)
        XCTAssertTrue(amount.isHiddenOrHasHiddenAncestor)
        mode.selectItem(at:1); XCTAssertTrue(mode.sendAction(mode.action,to:mode.target))
        let hz=try control("lfo.timebase",NSPopUpButton.self)
        hz.selectItem(at:0); XCTAssertTrue(hz.sendAction(hz.action,to:hz.target))
        let frequency=try control("lfo.frequency",DragValueField.self)
        XCTAssertTrue(frequency.onDragStart?() == true); frequency.onDragChange?(50); frequency.onDragEnd?()
        XCTAssertEqual(editor.track.clip(c.id)?.activeLFO(.scale)?.frequencyHz,2)
        editor.view.frame=NSRect(x:0,y:0,width:580,height:1700); editor.view.layoutSubtreeIfNeeded()
        let bitmap=try XCTUnwrap(editor.lfoEditor.bitmapImageRepForCachingDisplay(in:editor.lfoEditor.bounds))
        editor.lfoEditor.cacheDisplay(in:editor.lfoEditor.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/my-movie-lfo-inspector.png"))
        var locked=editor.track; locked.layers[0].isLocked=true
        editor.load(locked,projectURL:nil); timeline.onImageSelect?(c.id,track.layers[0].id)
        XCTAssertFalse(mode.isEnabled); XCTAssertFalse(amount.isEnabled)
        editor.onChange=nil; editor.onPreview=nil
    }

    func testMP4MatchesLFOCommonRendererOnEveryFrame() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let audio=directory.appendingPathComponent("tone.wav")
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let pcm=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:14400)); pcm.frameLength=14400
        pcm.floatChannelData![0].initialize(repeating:0,count:14400)
        do { let file=try AVAudioFile(forWriting:audio,settings:format.settings); try file.write(from:pcm) }
        var c=VisualClip(start:0,end:0.3,effects:ImageEffects(gradientBackground:.init(colorA:RGBColor(.red),colorB:RGBColor(.blue),position:0,width:1000)))
        var lfo=LFOSettings(); lfo.timebase = .hertz; lfo.frequencyHz=4; lfo.amount=500; lfo.curve=100
        c.setAutomation(.init(parameter:.gradientPosition,mode:.lfo,lfo:lfo))
        lfo.frequencyHz=2; lfo.amount=40; lfo.phaseDegrees=90
        c.setAutomation(.init(parameter:.gradientOpacity,mode:.lfo,lfo:lfo))
        var track=VisualTrack(); track.layers[0].clips=[c]
        let features=try AudioAnalyzer.analyze(url:audio)
        let scene=SceneSettings(spectrum:false)
        let output=directory.appendingPathComponent("lfo.mp4")
        try await VideoExporter.export(visuals:track,projectURL:ProjectStorage.projectURL(for:audio),audioURL:audio,features:features,settings:scene,destination:output,cancellation:ExportCancellation(),progress:{ _ in })
        let asset=AVURLAsset(url:output)
        let reader=try AVAssetReader(asset:asset)
        let video=try await asset.loadTracks(withMediaType:.video)
        let decoded=AVAssetReaderTrackOutput(track:try XCTUnwrap(video.first),outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(decoded); XCTAssertTrue(reader.startReading())
        let canvas=try EffectTestCanvas(); var count=0
        while let sample=decoded.copyNextSampleBuffer() {
            let time=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try canvas.draw([(c,0)],time:time,video:true)
            let buffer=try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            let bytes=try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to:UInt8.self)
            let stride=CVPixelBufferGetBytesPerRow(buffer)
            for (x,y) in [(960,540),(400,400),(1400,700)] {
                let expected=canvas.pixel(x,y)
                for channel in 0..<3 { XCTAssertEqual(Double(bytes[y*stride+x*4+channel]),Double(expected[channel]),accuracy:18,"frame \(count)") }
            }
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            count += 1
        }
        XCTAssertEqual(reader.status,.completed); XCTAssertEqual(count,9)
    }

}
