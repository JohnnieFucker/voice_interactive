import AVFoundation
import AudioToolbox
import AudioExceptionGuard
import CoreAudio
import OSLog

struct AudioDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let id: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let isVirtual: Bool
}

enum AudioDevices {
    static func list() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var result: Unmanaged<CFString>?
                var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result) == noErr else { return nil }
                return result?.takeUnretainedValue() as String?
            }
            func hasStreams(_ scope: AudioObjectPropertyScope) -> Bool {
                var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                var size: UInt32 = 0
                return AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr && size > 0
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName), !uid.hasPrefix("CADefaultDeviceAggregate-") else { return nil }
            var transport: UInt32 = 0
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bytes = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &transport)
            let virtual = transport == kAudioDeviceTransportTypeVirtual || uid == "MiRemoteV2ch_UID" || name.hasPrefix("BlackHole ")
            return AudioDevice(deviceID: id, id: uid, name: name, hasInput: hasStreams(kAudioDevicePropertyScopeInput), hasOutput: hasStreams(kAudioDevicePropertyScopeOutput), isVirtual: virtual)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func setDefaultInput(uid: String) throws {
        guard let selected = list().first(where: { $0.id == uid && $0.hasInput }) else { throw AudioFailure("所选麦克风已断开，请刷新设备") }
        var id = selected.deviceID
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        guard status == noErr else { throw AudioFailure("无法切换系统输入设备（\(status)）") }
    }
}

struct AudioFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum VoiceDiagnostics {
    static let logger = Logger(subsystem: "dev.remotevibe", category: "voice")
}

struct AudioBacklog {
    static let maximumSamples = 48_000 // 16 kHz，最多积压 3 秒。
    private(set) var samples = 0

    mutating func enqueue(_ count: Int) -> Bool {
        guard count > 0, count <= Self.maximumSamples - samples else { return false }
        samples += count
        return true
    }

    mutating func complete(_ count: Int) { samples = max(0, samples - max(0, count)) }
    mutating func reset() { samples = 0 }
}

final class AudioBridge {
    var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "dev.remotevibe.audio", qos: .userInitiated)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var outputDeviceID: AudioDeviceID?

    private func isOutputBound(to deviceID: AudioDeviceID, engine: AVAudioEngine) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var actual = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
        guard status == noErr, actual == deviceID else {
            VoiceDiagnostics.logger.error("Audio output mismatch: expected=\(deviceID) actual=\(actual) status=\(status)")
            return false
        }
        return true
    }
    private var observer: NSObjectProtocol?
    private var session = UUID()
    private var playback = UUID()
    private var accepting = false
    private var pending = 0
    private var backlog = AudioBacklog()
    private var drain: (() -> Void)?
    private var drainTimeout: DispatchWorkItem?

    func configure(uid: String, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.stopOnQueue()
            guard let device = AudioDevices.list().first(where: { $0.id == uid && $0.isVirtual && $0.hasInput && $0.hasOutput }) else {
                DispatchQueue.main.async { completion(false, "请选择可用的虚拟音频设备") }; return
            }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: self.format)
            guard let unit = engine.outputNode.audioUnit else {
                DispatchQueue.main.async { completion(false, "无法打开音频输出") }; return
            }
            var id = device.deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                DispatchQueue.main.async { completion(false, "无法打开所选虚拟音频设备（\(status)）") }; return
            }
            do {
                engine.prepare()
                try engine.start()
                guard self.isOutputBound(to: device.deviceID, engine: engine) else {
                    throw AudioFailure("音频实际输出与所选虚拟设备不一致，已停止连接")
                }
                guard RemoteMicTryPlayAudioPlayerNode(player) else { throw AudioFailure("虚拟音频设备未就绪") }
                self.engine = engine
                self.player = player
                self.outputDeviceID = device.deviceID
                VoiceDiagnostics.logger.info("Audio output verified: device=\(device.name, privacy: .public) id=\(device.deviceID)")
                let generation = self.session
                self.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard self.session == generation else { return }
                        self.stopOnQueue()
                        DispatchQueue.main.async { self.onFailure?("音频设备发生变化，请刷新并重新连接音频") }
                    }
                }
                DispatchQueue.main.async { completion(true, "音频已连接：\(device.name)") }
            } catch {
                player.stop(); engine.stop()
                DispatchQueue.main.async { completion(false, "音频连接失败：\(error.localizedDescription)") }
            }
        }
    }

    func begin() {
        queue.async {
            self.playback = UUID()
            self.player?.stop()
            self.pending = 0
            self.backlog.reset()
            self.drain = nil
            self.drainTimeout?.cancel(); self.drainTimeout = nil
            guard let engine = self.engine, engine.isRunning, let player = self.player, RemoteMicTryPlayAudioPlayerNode(player) else {
                self.accepting = false
                DispatchQueue.main.async { self.onFailure?("音频设备不可用，请重新连接音频") }; return
            }
            guard let deviceID = self.outputDeviceID, self.isOutputBound(to: deviceID, engine: engine) else {
                self.stopOnQueue()
                DispatchQueue.main.async { self.onFailure?("音频输出已偏离所选虚拟设备，本次录音已停止") }; return
            }
            self.accepting = true
        }
    }

    func write(_ samples: [Int16], gainDB: Double) {
        guard !samples.isEmpty else { return }
        queue.async {
            guard self.accepting else { return }
            guard let engine = self.engine, engine.isRunning, let player = self.player else {
                self.stopOnQueue()
                DispatchQueue.main.async { self.onFailure?("录音期间音频引擎停止，请重新连接音频") }; return
            }
            guard let deviceID = self.outputDeviceID, self.isOutputBound(to: deviceID, engine: engine) else {
                self.stopOnQueue()
                DispatchQueue.main.async { self.onFailure?("音频输出已偏离所选虚拟设备，本次录音已停止") }; return
            }
            let processed = PCMPostprocessor.process(samples, gainDB: gainDB)
            let sampleCount = processed.count
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(sampleCount)), let channel = buffer.floatChannelData?[0] else {
                self.stopOnQueue()
                DispatchQueue.main.async { self.onFailure?("无法分配音频缓冲，本次录音已停止") }; return
            }
            buffer.frameLength = AVAudioFrameCount(processed.count)
            for (index, sample) in processed.enumerated() { channel[index] = Float(sample) / 32_768 }
            guard self.backlog.enqueue(processed.count) else {
                VoiceDiagnostics.logger.error("Audio backlog exceeded: pending_buffers=\(self.pending) pending_samples=\(self.backlog.samples) incoming_samples=\(processed.count)")
                self.stopOnQueue()
                DispatchQueue.main.async { self.onFailure?("音频积压超过 3 秒，本次录音已停止，请重新连接音频") }; return
            }
            self.pending += 1
            let token = self.playback
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard token == self.playback else { return }
                    self.pending = max(0, self.pending - 1)
                    self.backlog.complete(sampleCount)
                    if !self.accepting && self.pending == 0 { self.finishDrain() }
                }
            }
        }
    }

    func end(completion: @escaping () -> Void) {
        queue.async {
            self.accepting = false
            VoiceDiagnostics.logger.info("Audio drain: pending_buffers=\(self.pending) pending_samples=\(self.backlog.samples)")
            self.drain = completion
            if self.pending == 0 { self.finishDrain(); return }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                VoiceDiagnostics.logger.error("Audio drain timed out: pending_samples=\(self.backlog.samples)")
                self.player?.stop()
                self.pending = 0
                self.backlog.reset()
                self.finishDrain()
            }
            self.drainTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 3.5, execute: timeout)
        }
    }

    private func finishDrain() {
        drainTimeout?.cancel(); drainTimeout = nil
        let completion = drain
        drain = nil
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        session = UUID()
        playback = UUID()
        accepting = false
        pending = 0
        backlog.reset()
        player?.stop(); engine?.stop()
        player = nil; engine = nil
        outputDeviceID = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        finishDrain()
    }
}
