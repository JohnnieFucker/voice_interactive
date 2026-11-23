import XCTest
@testable import RemoteVibe

final class RemoteVibeTests: XCTestCase {
    func testSharedRemoteFilterMatchesEdgesWithoutBlockingOtherKeys() {
        var filter = RemoteEventFilter()
        let left = RemoteNativeEvent(code: 123, system: false)
        let enter = RemoteNativeEvent(code: 36, system: false)
        filter.arm(.left, down: true, now: 1)
        XCTAssertFalse(filter.suppress(enter, down: true, repeating: false, now: 1.01))
        XCTAssertFalse(filter.suppress(left, down: false, repeating: false, now: 1.01))
        XCTAssertTrue(filter.suppress(left, down: true, repeating: false, now: 1.02))
        XCTAssertFalse(filter.suppress(left, down: true, repeating: false, now: 1.03))
        XCTAssertTrue(filter.suppress(left, down: true, repeating: true, now: 2))
        filter.arm(.left, down: false, now: 2.01)
        XCTAssertTrue(filter.suppress(left, down: false, repeating: false, now: 2.02))
        XCTAssertFalse(filter.suppress(left, down: true, repeating: true, now: 2.03))
    }

    func testSharedRemoteFilterExpiresAndSeparatesMediaKeys() {
        var filter = RemoteEventFilter()
        filter.arm(.volumeUp, down: true, now: 1)
        XCTAssertFalse(filter.suppress(RemoteNativeEvent(code: 0, system: false), down: true, repeating: false, now: 1.01))
        XCTAssertTrue(filter.suppress(RemoteNativeEvent(code: 0, system: true), down: true, repeating: false, now: 1.02))
        filter.arm(.ok, down: true, now: 2)
        XCTAssertFalse(filter.suppress(RemoteNativeEvent(code: 36, system: false), down: true, repeating: false, now: 2.2))
        filter = RemoteEventFilter()
        XCTAssertFalse(filter.suppress(RemoteNativeEvent(code: 0, system: true), down: true, repeating: true, now: 3))
    }

    func testOriginalConfigurationRemainsReadable() throws {
        let data = Data(#"{"inputMethod":"我的输入法","voiceShortcut":{"code":49,"modifiers":4352,"label":"⌃⌘Space"},"inputDeviceUID":"saved-mic","bindings":{"focus":{"code":18,"modifiers":6400,"label":"⌃⌥⌘1"}}}"#.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(configuration.inputMethod, "我的输入法")
        XCTAssertEqual(configuration.inputDeviceUID, "saved-mic")
        XCTAssertEqual(configuration.voiceShortcut?.code, 49)
        XCTAssertEqual(configuration.buttonBindings["left"]?.action, .previousPane)
        XCTAssertFalse(configuration.mappingEnabled)
    }

    func testPartialConfigurationUsesSafeDefaults() throws {
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"{"version":2,"gainDB":99,"buttonBindings":{"ok":{"action":"none"}}}"#.utf8))
        XCTAssertEqual(configuration.gainDB, 24)
        XCTAssertEqual(configuration.buttonBindings["ok"]?.action, ButtonAction.none)
        XCTAssertEqual(configuration.buttonBindings["voice"]?.action, .voice)
        XCTAssertEqual(configuration.microphoneSource, .mac)
    }

    func testRoundTripPreservesDeviceAndCustomButton() throws {
        var original = Configuration()
        original.peripheralID = UUID()
        original.microphoneSource = .remote
        original.buttonBindings["tv"] = .init(action: .shortcut, shortcut: .init(code: 49, modifiers: 256, label: "⌘Space"))
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, decoded)
    }

    func testOldDefaultWindowBindingsBecomePaneBindings() throws {
        let data = Data(#"{"version":2,"buttonBindings":{"left":{"action":"previousWindow"},"right":{"action":"nextWindow"},"menu":{"action":"nextWindow"}}}"#.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(configuration.buttonBindings["left"]?.action, .previousPane)
        XCTAssertEqual(configuration.buttonBindings["right"]?.action, .nextPane)
        XCTAssertEqual(configuration.buttonBindings["menu"]?.action, .nextWindow)
    }

    func testMigrationPreservesCustomBindingsAndNewWindowChoices() throws {
        let old = Data(#"{"version":2,"buttonBindings":{"left":{"action":"shortcut","shortcut":{"code":49,"modifiers":256,"label":"⌘Space"}},"right":{"action":"none"}}}"#.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: old)
        XCTAssertEqual(configuration.buttonBindings["left"]?.action, .shortcut)
        XCTAssertEqual(configuration.buttonBindings["right"]?.action, ButtonAction.none)
        let current = Data(#"{"version":3,"buttonBindings":{"left":{"action":"previousWindow"},"right":{"action":"nextWindow"}}}"#.utf8)
        let currentConfiguration = try JSONDecoder().decode(Configuration.self, from: current)
        XCTAssertEqual(currentConfiguration.buttonBindings["left"]?.action, .previousWindow)
        XCTAssertEqual(currentConfiguration.buttonBindings["right"]?.action, .nextWindow)
    }

    func testInterruptedOnboardingPreservesStepAndConfiguration() throws {
        var configuration = Configuration()
        configuration.inputMethod = "微信输入法"
        configuration.onboardingStep = .controls
        configuration.onboardingVoiceVerified = true
        configuration.buttonBindings["menu"] = .init(action: .escape)
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.onboardingStep, .controls)
        XCTAssertTrue(decoded.onboardingVoiceVerified)
        XCTAssertFalse(decoded.onboardingComplete)
        XCTAssertEqual(decoded.inputMethod, "微信输入法")
        XCTAssertEqual(decoded.buttonBindings["menu"]?.action, .escape)
    }

    func testOldConfigurationStartsGuideWithoutDiscardingItsShortcut() throws {
        let data = Data(#"{"version":3,"inputMethod":"Typeless","voiceShortcut":{"code":63,"modifiers":0,"label":"Fn","modifierOnly":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(decoded.onboardingStep, .welcome)
        XCTAssertFalse(decoded.onboardingComplete)
        XCTAssertEqual(decoded.inputMethod, "Typeless")
        XCTAssertEqual(decoded.voiceShortcut?.code, 63)
    }

    func testOnboardingCanGoBackAndReachCompletion() {
        let steps = OnboardingStep.allCases
        XCTAssertNil(steps.first?.previous)
        XCTAssertNil(steps.last?.next)
        XCTAssertEqual(steps.first?.progress, 0)
        XCTAssertEqual(steps.last?.progress, 1)
        for pair in zip(steps, steps.dropFirst()) {
            XCTAssertEqual(pair.0.next, pair.1)
            XCTAssertEqual(pair.1.previous, pair.0)
            XCTAssertLessThan(pair.0.progress, pair.1.progress)
        }
    }

    func testGuideBlocksUnrelatedPhysicalKeysDuringSetup() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.allowsPhysicalAction(.ok))
            XCTAssertFalse(step.allowsPhysicalAction(.power))
            XCTAssertFalse(step.allowsPhysicalAction(.back))
        }
        XCTAssertTrue(OnboardingStep.voiceTest.allowsPhysicalAction(.voice))
        XCTAssertFalse(OnboardingStep.voiceTest.allowsPhysicalAction(.left))
        XCTAssertTrue(OnboardingStep.controls.allowsPhysicalAction(.left))
        XCTAssertTrue(OnboardingStep.controls.allowsPhysicalAction(.right))
        XCTAssertFalse(OnboardingStep.controls.allowsPhysicalAction(.voice))
        XCTAssertTrue(RemoteButton.allCases.allSatisfy { !OnboardingStep.remote.allowsPhysicalAction($0) })
    }

    func testBadOrFutureConfigurationIsRejected() {
        for json in [#"{"version":99}"#, #"{"voiceShortcut":{"code":65535,"modifiers":256,"label":"bad"}}"#, #"{"buttonBindings":{"ok":{"action":"unknown"}}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)))
        }
    }

    func testModifierOnlyAndFnShortcuts() {
        let fn = Shortcut.fromModifiers(.function)
        XCTAssertEqual(fn?.code, 63)
        XCTAssertTrue(fn?.isValid == true)
        XCTAssertEqual(fn?.modifierOnly, true)
        let commandControl = Shortcut.fromModifiers([.command, .control])
        XCTAssertTrue(commandControl?.isValid == true)
        XCTAssertEqual(commandControl?.label, "⌃⌘")
        XCTAssertNil(Shortcut.fromModifiers(.shift))
        XCTAssertFalse(Shortcut(code: 49, modifiers: 0, label: "Space").isValid)
    }

    func testRemoteReportWithAndWithoutReportPrefix() {
        let expected: Set<UInt16> = [0x50, 0x28]
        XCTAssertEqual(RemoteReportParser.usages(reportID: 1, data: Data([0x50, 0, 0x28, 0, 0, 0])), expected)
        XCTAssertEqual(RemoteReportParser.usages(reportID: 1, data: Data([1, 0x50, 0, 0x28, 0, 0, 0])), expected)
        XCTAssertEqual(RemoteReportParser.usages(reportID: 1, data: Data(repeating: 0, count: 6)), [])
        XCTAssertNil(RemoteReportParser.usages(reportID: 2, data: Data([0x50, 0])))
        XCTAssertNil(RemoteReportParser.usages(reportID: 1, data: Data([0x50])))
        XCTAssertNil(RemoteReportParser.usages(reportID: 1, data: Data()))
    }

    func testVoiceCapabilitiesRejectUnsupportedSampleRate() throws {
        let supported = try XCTUnwrap(ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0, 120])))
        XCTAssertEqual(supported.frameSize, 120)
        XCTAssertTrue(ATVVProtocol.supportsAudio(sampleRate: supported.sampleRate))
        let unsupported = try XCTUnwrap(ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x01, 0x03, 0, 120])))
        XCTAssertFalse(ATVVProtocol.supportsAudio(sampleRate: unsupported.sampleRate))
        XCTAssertNil(ATVVCapabilities.parse(Data([0x0B, 1])))
    }

    func testMicrophoneExtensionUsesCurrentSessionAndRequiresV10() {
        XCTAssertNil(ATVVProtocol.microphoneExtend(version: 0x0009, sessionID: 7))
        XCTAssertEqual(ATVVProtocol.microphoneExtend(version: 0x0100, sessionID: 7), Data([0x0E, 7]))
        XCTAssertEqual(ATVVProtocol.microphoneExtend(version: 0x0100, sessionID: 255), Data([0x0E, 255]))
    }

    func testADPCMKnownVectorsAndClipping() {
        let decoder = IMAADPCMDecoder()
        XCTAssertEqual(decoder.decode(Data([0x77])), [11, 41])
        decoder.reset()
        XCTAssertEqual(decoder.decode(Data([0xFF])), [-11, -41])
        decoder.reset(predictor: 32_767, stepIndex: 88)
        XCTAssertEqual(decoder.decode(Data([0x77])), [32_767, 32_767])
        decoder.reset(predictor: -32_768, stepIndex: 88)
        XCTAssertEqual(decoder.decode(Data([0xFF])), [-32_768, -32_768])
    }

    func testAudioFramesAcrossBluetoothPackets() {
        var accumulator = FrameAccumulator()
        XCTAssertTrue(accumulator.append(Data([1, 2]), frameSize: 3).isEmpty)
        XCTAssertEqual(accumulator.append(Data([3, 4, 5, 6, 7]), frameSize: 3), [Data([1, 2, 3]), Data([4, 5, 6])])
        XCTAssertEqual(accumulator.pending, Data([7]))
        accumulator.reset()
        XCTAssertTrue(accumulator.pending.isEmpty)
        XCTAssertTrue(accumulator.append(Data([1]), frameSize: 0).isEmpty)
    }
    func testAudioBacklogLimitsDurationRegardlessOfPacketSize() {
        var smallPackets = AudioBacklog()
        for _ in 0..<200 { XCTAssertTrue(smallPackets.enqueue(240)) }
        XCTAssertEqual(smallPackets.samples, AudioBacklog.maximumSamples)
        XCTAssertFalse(smallPackets.enqueue(1))
        XCTAssertEqual(smallPackets.samples, AudioBacklog.maximumSamples)

        var largePackets = AudioBacklog()
        XCTAssertTrue(largePackets.enqueue(AudioBacklog.maximumSamples))
        XCTAssertFalse(largePackets.enqueue(240))
        smallPackets.complete(240)
        XCTAssertTrue(smallPackets.enqueue(240))
        XCTAssertEqual(smallPackets.samples, largePackets.samples)
    }

    func testAudioBacklogRejectsInvalidWritesAndResetsBetweenSessions() {
        var backlog = AudioBacklog()
        XCTAssertFalse(backlog.enqueue(0))
        XCTAssertFalse(backlog.enqueue(-1))
        XCTAssertFalse(backlog.enqueue(Int.max))
        XCTAssertEqual(backlog.samples, 0)
        XCTAssertTrue(backlog.enqueue(240))
        backlog.complete(-1)
        XCTAssertEqual(backlog.samples, 240)
        backlog.complete(480)
        XCTAssertEqual(backlog.samples, 0)
        XCTAssertTrue(backlog.enqueue(480))
        backlog.reset()
        XCTAssertEqual(backlog.samples, 0)
        XCTAssertTrue(backlog.enqueue(AudioBacklog.maximumSamples))
    }

    func testKeyRepeatStartsAfterDelayAndStopsOnRelease() {
        let repeater = KeyRepeater()
        var count = 0
        let repeated = expectation(description: "Repeated while held")
        repeater.start(delay: 0.02, interval: 0.01) {
            count += 1
            if count == 3 {
                repeater.stop()
                repeated.fulfill()
            }
            return true
        }
        XCTAssertEqual(count, 0)
        wait(for: [repeated], timeout: 1)
        let stopped = expectation(description: "No more deletes after release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { stopped.fulfill() }
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(count, 3)
    }

    func testKeyRepeatCancelsPendingStartAndStopsWhenActionIsRejected() {
        let repeater = KeyRepeater()
        let generation = repeater.generation
        repeater.start(delay: 0.02, interval: 0.01) { XCTFail("Released before repeat delay"); return true }
        repeater.stop()
        XCTAssertNotEqual(repeater.generation, generation)
        var count = 0
        repeater.start(delay: 0.02, interval: 0.01) { count += 1; return false }
        let settled = expectation(description: "Rejected action stops repetition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(count, 1)
        repeater.stop()
    }

}
