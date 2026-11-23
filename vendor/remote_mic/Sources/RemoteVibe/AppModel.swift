import AppKit
import OSLog
import CoreBluetooth
import Combine
import IOKit.hid

final class AppModel: ObservableObject {
    @Published var settings = Configuration() {
        didSet {
            guard !loadingSettings else { return }
            applyChanges(from: oldValue)
            persist()
        }
    }
    @Published var message = "先配对遥控器，再连接并开启按键映射。"
    @Published var connectionStatus = "未连接"
    @Published var inputStatus = "按键映射已关闭"
    @Published var audioStatus = "未连接音频"
    @Published var deviceName = "小米蓝牙遥控器"
    @Published var battery: Int?
    @Published var connected = false
    @Published var devices = AudioDevices.list()
    @Published var pressed = Set<RemoteButton>()
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var inputGranted = RemoteInput.hasPermission
    @Published var bluetoothAuthorization = CBManager.authorization
    @Published private(set) var voicePhase = VoicePhase.idle
    @Published private(set) var audioReady = false
    @Published private(set) var connecting = false
    @Published private(set) var loadError: String?
    @Published private(set) var persistenceError: String?
    @Published private(set) var inputConnected = false
    @Published private(set) var setupVoiceStarted = false
    @Published private(set) var setupVoiceStopped = false
    @Published private(set) var setupAudioReceived = false
    @Published private(set) var setupTestedButtons = Set<RemoteButton>()

    enum VoicePhase { case idle, starting, recording, stopping }
    private let bluetooth = BluetoothBridge()
    private let input = RemoteInput()
    private let audio = AudioBridge()
    private let performer = ActionPerformer()
    private let keyRepeater = KeyRepeater()
    private var repeatOwner: RemoteButton?
    private let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteVibe/settings.json")
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var voiceGeneration = UUID()
    private var audioGeneration = UUID()
    private var preRoll: [Int16] = []
    private var sessionShortcut: Shortcut?
    private var sessionTrigger = VoiceTrigger.toggle
    private var sessionSource = MicrophoneSource.mac
    private var voiceOwner: RemoteButton?
    private var wantsConnection = false
    private var suspended = false
    private var loadingSettings = true
    private var sessionPhysical = false
    private var sessionCancelled = false

    init() {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let data = try Data(contentsOf: settingsURL)
                let loaded = try JSONDecoder().decode(Configuration.self, from: data)
                if loaded.version < 4 {
                    let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings-v\(loaded.version)-backup.json")
                    if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
                }
                settings = loaded
                settings.version = 4
            } catch { loadError = "无法读取原配置，已保留原文件。\(error.localizedDescription)" }
        }
        configureCallbacks()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.suspended = true
            self.cancelVoice()
            self.input.stop()
            self.bluetooth.stop()
            self.audio.stop()
            self.audioReady = false
            self.audioGeneration = UUID()
            self.pressed.removeAll()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.suspended = false
            if self.wantsConnection { self.bluetooth.start(cachedID: self.settings.peripheralID) }
            self.applyInput()
            self.configureAudio()
        }
        loadingSettings = false
        persist()
        applyInput()
        configureAudio()
    }

    private func configureCallbacks() {
        input.onStatus = { [weak self] status in
            guard let self else { return }
            self.inputStatus = status
            self.inputConnected = self.input.isConnected
            if !self.inputConnected { self.stopKeyRepeat() }
        }
        input.onButton = { [weak self] button, down in self?.handle(button, down: down) }
        bluetooth.onStatus = { [weak self] status, ready in
            self?.connectionStatus = status
            self?.connected = ready
        }
        bluetooth.onDevice = { [weak self] name, battery in self?.deviceName = name; self?.battery = battery }
        bluetooth.onReady = { [weak self] id in
            guard let self else { return }
            if self.settings.peripheralID != id { self.settings.peripheralID = id }
        }
        bluetooth.shouldOpenMicrophone = { [weak self] in
            guard let self else { return false }
            return !self.suspended && (self.settings.onboardingComplete || self.settings.onboardingStep == .voiceTest) && self.settings.mappingEnabled && self.settings.microphoneSource == .remote && self.audioReady && self.accessibilityGranted && self.inputGranted && self.input.isConnected
        }
        bluetooth.onVoice = { [weak self] down in
            guard let self, self.settings.microphoneSource == .remote else { return }
            if down { self.pressed.insert(.voice); self.beginVoice(owner: .voice) }
            else { self.pressed.remove(.voice); self.endVoice() }
        }
        bluetooth.onSamples = { [weak self] samples in self?.receive(samples) }
        audio.onFailure = { [weak self] message in
            guard let self else { return }
            VoiceDiagnostics.logger.error("Audio failure: \(message, privacy: .public)")
            self.audioReady = false
            self.audioStatus = message
            self.cancelVoice()
            self.bluetooth.closeMicrophone()
        }
    }

    private func persist() {
        // 读取失败时不自动覆盖用户文件，需用户主动重置配置。
        guard loadError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "配置保存失败：\(error.localizedDescription)"
            message = persistenceError ?? "配置保存失败"
        }
    }

    func retrySavingConfiguration() { persist() }

    func resetUnreadableSettings() {
        guard loadError != nil else { return }
        do {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings-unreadable-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: settingsURL, to: backup)
            loadError = nil
            settings = Configuration()
            message = "原配置已备份，新配置已保存。"
        } catch { message = "无法备份原配置，未重置：\(error.localizedDescription)" }
    }

    private func applyChanges(from old: Configuration) {
        if old.buttonBindings != settings.buttonBindings || old.mappingEnabled != settings.mappingEnabled || old.onboardingStep != settings.onboardingStep {
            stopKeyRepeat()
        }
        if old.inputMethod != settings.inputMethod || old.inputDeviceUID != settings.inputDeviceUID || old.microphoneSource != settings.microphoneSource || old.voiceShortcut != settings.voiceShortcut || old.voiceTrigger != settings.voiceTrigger || old.virtualDeviceUID != settings.virtualDeviceUID {
            cancelVoice()
            bluetooth.closeMicrophone()
            pressed.remove(.voice)
            if settings.onboardingVoiceVerified { settings.onboardingVoiceVerified = false }
            resetVoiceCheck()
        }
        if old.buttonBindings != settings.buttonBindings {
            cancelVoice(); bluetooth.closeMicrophone()
            setupTestedButtons.removeAll()
            if settings.onboardingControlsVerified { settings.onboardingControlsVerified = false }
        }
        if old.mappingEnabled != settings.mappingEnabled { applyInput() }
        if old.microphoneSource != settings.microphoneSource || old.virtualDeviceUID != settings.virtualDeviceUID { configureAudio() }
    }

    private func applyInput() {
        guard !suspended, settings.mappingEnabled else { input.stop(); pressed.removeAll(); cancelVoice(); bluetooth.closeMicrophone(); return }
        input.start()
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        inputGranted = RemoteInput.hasPermission
        bluetoothAuthorization = CBManager.authorization
        if !accessibilityGranted || !inputGranted {
            if input.isRunning { cancelVoice(); bluetooth.closeMicrophone(); input.stop(); pressed.removeAll() }
        } else if settings.mappingEnabled && !input.isRunning && !suspended { input.start() }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func requestInputMonitoring() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func connect() {
        guard !suspended else { return }
        wantsConnection = true
        connecting = true
        bluetooth.reconnectNow(cachedID: settings.peripheralID)
        input.stop(); applyInput()
    }
    func disconnect() {
        wantsConnection = false
        connecting = false
        cancelVoice()
        bluetooth.stop()
        input.stop()
        pressed.removeAll()
        message = "蓝牙已断开；按键映射开关控制已配对遥控器的按键监听。"
    }
    func retryInput() { input.stop(); applyInput() }
    func refreshDevices() { devices = AudioDevices.list() }
    var virtualDevices: [AudioDevice] { devices.filter { $0.isVirtual && $0.hasInput && $0.hasOutput } }

    func configureAudio() {
        if voicePhase != .idle { cancelVoice(); bluetooth.closeMicrophone() }
        audioGeneration = UUID()
        let generation = audioGeneration
        audioReady = false
        guard !suspended, settings.microphoneSource == .remote else { audio.stop(); audioStatus = "使用 Mac 系统输入设备"; return }
        guard !settings.virtualDeviceUID.isEmpty else { audio.stop(); audioStatus = "请选择虚拟音频设备"; return }
        audioStatus = "正在连接音频…"
        audio.configure(uid: settings.virtualDeviceUID) { [weak self] ready, status in
            guard let self, self.audioGeneration == generation else { return }
            self.audioReady = ready
            self.audioStatus = status
        }
    }

    func applyDefaultInput() {
        let uid = settings.microphoneSource == .remote ? settings.virtualDeviceUID : settings.inputDeviceUID
        guard !uid.isEmpty else { message = "沿用当前系统默认输入设备。"; return }
        do { try AudioDevices.setDefaultInput(uid: uid); message = "系统默认输入已切换；输入法如固定麦克风，需同步选择。" }
        catch { message = error.localizedDescription }
    }

    private func handle(_ button: RemoteButton, down: Bool) {
        if down || repeatOwner == button { stopKeyRepeat() }
        if down { pressed.insert(button) } else { pressed.remove(button) }
        guard settings.mappingEnabled else { return }
        guard settings.onboardingComplete || settings.onboardingStep.allowsPhysicalAction(button) else { return }
        if !settings.onboardingComplete && settings.onboardingStep == .controls {
            let expected: ButtonAction = button == .left ? .previousPane : .nextPane
            guard settings.buttonBindings[button.rawValue]?.action == expected else {
                message = "请先在向导中将左右键设为切换分屏。"; return
            }
        }
        if button == .voice && settings.microphoneSource == .remote { return }
        if !down {
            if voiceOwner == button { endVoice() }
            return
        }
        let binding = settings.buttonBindings[button.rawValue] ?? .init(action: .none)
        if binding.action == .voice {
            guard settings.microphoneSource == .mac else { message = "使用遥控器麦克风时，请按住实体语音键。"; return }
            beginVoice(owner: button)
        } else { perform(binding, origin: button) }
    }

    func perform(_ binding: ButtonBinding, origin: RemoteButton? = nil) {
        guard binding.action != .none else { return }
        if binding.action == .voice { toggleVoiceTest(); return }
        guard voicePhase == .idle else { message = "请先结束语音输入再切换窗口或发送按键。"; return }
        guard binding.action != .shortcut || binding.shortcut?.isValid == true else { message = "请先录制该按键的自定义快捷键。"; return }
        let repeatGeneration = keyRepeater.generation
        if let origin, binding.action == .backspace { repeatOwner = origin }
        performer.activate(binding.action) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.message = error.localizedDescription
            case .success:
                if let code = binding.action.keyCode {
                    guard ActionPerformer.hasFocus, ActionPerformer.post(code: code, down: true), ActionPerformer.post(code: code, down: false) else { self.message = "无法发送按键，请检查辅助功能权限。"; return }
                } else if binding.action == .shortcut, let shortcut = binding.shortcut, !(ActionPerformer.hasFocus && ActionPerformer.tap(shortcut)) {
                    self.message = "无法发送快捷键，请检查辅助功能权限。"; return
                }
                if let origin, self.settings.onboardingStep == .controls, !self.settings.onboardingComplete,
                   (origin == .left && binding.action == .previousPane) || (origin == .right && binding.action == .nextPane) {
                    self.setupTestedButtons.insert(origin)
                }
                if let origin, binding.action == .backspace,
                   self.keyRepeater.generation == repeatGeneration, self.pressed.contains(origin) {
                    self.keyRepeater.start { [weak self] in
                        guard let self, self.settings.mappingEnabled, self.settings.onboardingComplete,
                              self.input.isConnected, self.pressed.contains(origin), self.voicePhase == .idle,
                              self.settings.buttonBindings[origin.rawValue] == binding, ActionPerformer.hasFocus else { return false }
                        return ActionPerformer.post(code: 51, down: true) && ActionPerformer.post(code: 51, down: false)
                    }
                }
                self.message = "已执行：\(binding.action.title)"
            }
        }
    }

    private func stopKeyRepeat() {
        keyRepeater.stop()
        repeatOwner = nil
    }

    func toggleVoiceTest() {
        if voicePhase == .idle { beginVoice(owner: nil) }
        else { endVoice() }
    }

    private func beginVoice(owner: RemoteButton?) {
        stopKeyRepeat()
        guard voicePhase == .idle else { return }
        guard let shortcut = settings.voiceShortcut, shortcut.isValid else { message = "请在连接与语音页录制输入法的语音快捷键。"; return }
        guard AXIsProcessTrusted() else { message = "请先授予辅助功能权限。"; return }
        if settings.microphoneSource == .remote && !audioReady { message = "遥控器音频尚未就绪，请连接虚拟音频设备。"; return }
        if owner != nil && settings.onboardingStep == .voiceTest && !settings.onboardingComplete {
            resetVoiceCheck()
            settings.onboardingVoiceVerified = false
        }
        voiceOwner = owner
        sessionPhysical = owner != nil
        sessionCancelled = false
        sessionShortcut = shortcut
        sessionTrigger = settings.voiceTrigger
        sessionSource = settings.microphoneSource
        voicePhase = .starting
        voiceGeneration = UUID()
        preRoll.removeAll(keepingCapacity: true)
        let sent = sessionTrigger == .toggle ? ActionPerformer.tap(shortcut) : ActionPerformer.postShortcut(shortcut, down: true)
        guard sent else { voicePhase = .idle; voiceOwner = nil; sessionShortcut = nil; message = "无法发送语音快捷键。"; return }
        voicePhase = .recording
        VoiceDiagnostics.logger.info("Voice input started: source=\(String(describing: self.sessionSource), privacy: .public) trigger=\(String(describing: self.sessionTrigger), privacy: .public)")
        if sessionPhysical && settings.onboardingStep == .voiceTest { setupVoiceStarted = true }
        if sessionSource == .remote { audio.begin() }
        message = "已发送语音启动快捷键，请说话。"
    }

    private func receive(_ samples: [Int16]) {
        if !samples.isEmpty && sessionPhysical && settings.onboardingStep == .voiceTest && (voicePhase == .starting || voicePhase == .recording) { setupAudioReceived = true }
        if voicePhase == .starting {
            guard preRoll.count + samples.count <= 32_000 else {
                cancelVoice(); bluetooth.closeMicrophone(); message = "语音启动过慢，本次语音已取消。"; return
            }
            preRoll.append(contentsOf: samples)
        } else if voicePhase == .recording && sessionSource == .remote { audio.write(samples, gainDB: settings.gainDB) }
    }

    private func endVoice() {
        voiceOwner = nil
        if voicePhase == .starting { voiceGeneration = UUID(); voicePhase = .idle; sessionShortcut = nil; preRoll.removeAll(); return }
        guard voicePhase == .recording else { return }
        VoiceDiagnostics.logger.info("Voice input stopping: source=\(String(describing: self.sessionSource), privacy: .public)")
        voicePhase = .stopping
        let generation = voiceGeneration
        let completion = { [weak self] in
            guard let self, self.voiceGeneration == generation else { return }
            self.finishVoice()
        }
        if sessionSource == .remote { audio.end(completion: completion) }
        else { completion() }
    }

    private func finishVoice() {
        defer { voicePhase = .idle; sessionShortcut = nil; preRoll.removeAll(); voiceOwner = nil }
        guard let shortcut = sessionShortcut else { return }
        if sessionTrigger == .hold {
            if !ActionPerformer.postShortcut(shortcut, down: false) { message = "无法释放语音快捷键，请检查辅助功能权限。"; return }
        } else {
            guard ActionPerformer.tap(shortcut) else { message = "无法发送语音停止快捷键，请在输入法中结束语音。"; return }
        }
        if sessionPhysical && !sessionCancelled && settings.onboardingStep == .voiceTest { setupVoiceStopped = true }
        message = "已发送语音停止快捷键。"
    }

    private func cancelVoice(reason: String = #function) {
        stopKeyRepeat()
        if voicePhase != .idle {
            VoiceDiagnostics.logger.info("Voice input cancelled: caller=\(reason, privacy: .public)")
        }
        sessionCancelled = true
        voiceGeneration = UUID()
        if voicePhase == .recording || voicePhase == .stopping { finishVoice() }
        else { voicePhase = .idle; voiceOwner = nil; sessionShortcut = nil; preRoll.removeAll() }
        audio.end(completion: {})
    }

    var setupPermissionsReady: Bool {
        accessibilityGranted && inputGranted && bluetoothAuthorization == .allowedAlways
    }
    var setupAudioReady: Bool {
        if settings.microphoneSource == .remote { return audioReady }
        let uid = settings.inputDeviceUID
        return devices.contains { $0.hasInput && (uid.isEmpty || $0.id == uid) }
    }
    var setupVoiceReady: Bool {
        setupVoiceStarted && setupVoiceStopped && voicePhase == .idle && (settings.microphoneSource == .mac || setupAudioReceived)
    }
    var setupControlsReady: Bool {
        setupTestedButtons.contains(.left) && setupTestedButtons.contains(.right) && settings.buttonBindings["left"]?.action == .previousPane && settings.buttonBindings["right"]?.action == .nextPane
    }
    var setupCanContinue: Bool {
        guard loadError == nil, persistenceError == nil, voicePhase == .idle else { return false }
        if settings.onboardingStep != .welcome && settings.onboardingStep != .permissions && !setupPermissionsReady { return false }
        switch settings.onboardingStep {
        case .welcome: return true
        case .permissions: return setupPermissionsReady
        case .remote: return connected && inputConnected && settings.mappingEnabled
        case .audio: return connected && inputConnected && setupAudioReady
        case .voiceTool: return connected && inputConnected && !settings.inputMethod.isEmpty && settings.voiceShortcut?.isValid == true
        case .voiceTest: return connected && inputConnected && setupAudioReady && setupVoiceReady && settings.onboardingVoiceVerified
        case .controls: return connected && inputConnected && setupControlsReady && settings.onboardingControlsVerified
        case .complete: return setupPermissionsReady && connected && inputConnected && setupAudioReady && settings.voiceShortcut?.isValid == true && settings.onboardingVoiceVerified && settings.onboardingControlsVerified
        }
    }

    private func resetVoiceCheck() {
        setupVoiceStarted = false
        setupVoiceStopped = false
        setupAudioReceived = false
    }

    func enterSetupStep(_ step: OnboardingStep) {
        cancelVoice()
        settings.onboardingStep = step
        if step == .permissions { refreshPermissions() }
        if step == .remote {
            settings.mappingEnabled = true
            if !connecting { connect() }
        }
        if step == .audio { refreshDevices(); configureAudio() }
        if step == .voiceTest {
            resetVoiceCheck()
            settings.onboardingVoiceVerified = false
        }
        if step == .controls {
            setupTestedButtons.removeAll()
            settings.onboardingControlsVerified = false
        }
    }

    func advanceSetup() {
        guard setupCanContinue else { return }
        if let next = settings.onboardingStep.next { enterSetupStep(next) }
        else {
            settings.onboardingComplete = true
            if persistenceError != nil { settings.onboardingComplete = false }
        }
    }

    func resumeSetup() {
        refreshPermissions()
        refreshDevices()
        let step = settings.onboardingStep
        guard step != .welcome && step != .permissions else { return }
        if setupPermissionsReady && !connecting { connect() }
        if step == .remote { settings.mappingEnabled = true }
        if step == .voiceTest { resetVoiceCheck(); settings.onboardingVoiceVerified = false }
        if step == .controls { setupTestedButtons.removeAll(); settings.onboardingControlsVerified = false }
    }

    func restartSetup() {
        let hadActiveVoice = voicePhase != .idle
        cancelVoice()
        settings.onboardingVoiceVerified = false
        settings.onboardingControlsVerified = false
        settings.onboardingStep = .welcome
        settings.onboardingComplete = false
        if !hadActiveVoice { message = "已重新打开配置向导，现有按键和音频设置保持不变。" }
    }

    func shutdown() {
        timer?.invalidate()
        cancelVoice()
        input.stop(); bluetooth.stop(); audio.stop()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
