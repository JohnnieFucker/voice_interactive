import CoreBluetooth
import Foundation
import OSLog

private final class PeripheralCallbacks: NSObject, CBPeripheralDelegate {
    weak var owner: BluetoothBridge?
    let generation: UUID
    init(owner: BluetoothBridge, generation: UUID) { self.owner = owner; self.generation = generation }
    private func current(_ peripheral: CBPeripheral) -> BluetoothBridge? {
        guard let owner, owner.accepts(peripheral, generation: generation) else { return nil }
        return owner
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        current(peripheral)?.discoveredServices(peripheral, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        current(peripheral)?.discoveredCharacteristics(peripheral, service: service, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        current(peripheral)?.notificationChanged(characteristic, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        current(peripheral)?.received(characteristic, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { current(peripheral)?.fail("遥控器没有接受语音命令，请重新连接") }
    }
}

final class BluetoothBridge: NSObject, CBCentralManagerDelegate {
    var onStatus: ((String, Bool) -> Void)?
    var onDevice: ((String, Int?) -> Void)?
    var onReady: ((UUID) -> Void)?
    var onVoice: ((Bool) -> Void)?
    var onSamples: (([Int16]) -> Void)?
    var shouldOpenMicrophone: (() -> Bool)?
    private let service = CBUUID(string: ATVVProtocol.serviceUUID)
    private let txID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlID = CBUUID(string: ATVVProtocol.controlUUID)
    private let batteryService = CBUUID(string: "180F")
    private let batteryID = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var callbacks: PeripheralCallbacks?
    private var generation = UUID()
    private var transmit: CBCharacteristic?
    private var subscribed = Set<CBUUID>()
    private var requestedCapabilities = false
    private var capabilities: ATVVCapabilities?
    private let decoder = IMAADPCMDecoder()
    private var accumulator = FrameAccumulator()
    private var pendingSync: (Int, Int)?
    private var streaming = false
    private var streamStartedAt: TimeInterval?
    private var receivedSamples = 0
    private var microphoneKeepAlive: Timer?
    private var sessionID: UInt8 = 0
    private var lastStop: TimeInterval?
    private var running = false
    private var cachedID: UUID?
    private var timeout: DispatchWorkItem?
    private var reconnect: DispatchWorkItem?
    private(set) var isReady = false
    private var battery: Int?

    func start(cachedID: UUID?) {
        guard !running else { return }
        running = true
        self.cachedID = cachedID
        if let central, central.state == .poweredOn { discover() }
        else {
            onStatus?("正在检查蓝牙…", false)
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        running = false
        reconnect?.cancel(); reconnect = nil
        central?.stopScan()
        if let peripheral, let central { closeMicrophone(); central.cancelPeripheralConnection(peripheral) }
        central?.delegate = nil
        central = nil
        reset()
        onStatus?("未连接", false)
    }

    func reconnectNow(cachedID: UUID?) { stop(); start(cachedID: cachedID) }

    fileprivate func accepts(_ candidate: CBPeripheral, generation: UUID) -> Bool {
        running && self.generation == generation && peripheral === candidate
    }

    private func reset() {
        timeout?.cancel(); timeout = nil
        stopStreaming(reason: "connection_reset")
        peripheral?.delegate = nil
        peripheral = nil
        callbacks = nil
        transmit = nil
        subscribed.removeAll()
        requestedCapabilities = false
        capabilities = nil
        isReady = false
        battery = nil
        generation = UUID()
        onDevice?("小米蓝牙遥控器", nil)
    }

    private func discover() {
        guard running, let central, central.state == .poweredOn else { return }
        if let cachedID, let candidate = central.retrievePeripherals(withIdentifiers: [cachedID]).first {
            connect(candidate); return
        }
        if let candidate = central.retrieveConnectedPeripherals(withServices: [service]).first {
            connect(candidate); return
        }
        onStatus?("正在搜索，请唤醒遥控器…", false)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ candidate: CBPeripheral) {
        guard running, peripheral == nil else { return }
        central?.stopScan()
        peripheral = candidate
        generation = UUID()
        let proxy = PeripheralCallbacks(owner: self, generation: generation)
        callbacks = proxy
        candidate.delegate = proxy
        onDevice?(candidate.name ?? "小米蓝牙遥控器", nil)
        onStatus?("正在连接…", false)
        setTimeout("连接超时，请唤醒遥控器后重试", seconds: 12)
        central?.connect(candidate, options: nil)
    }

    private func setTimeout(_ message: String, seconds: Double) {
        timeout?.cancel()
        let expected = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == expected else { return }
            self.fail(message)
        }
        timeout = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    fileprivate func fail(_ message: String) {
        guard running else { return }
        VoiceDiagnostics.logger.error("Bluetooth failure: \(message, privacy: .public)")
        let old = peripheral
        cachedID = nil
        reset()
        if let old { central?.cancelPeripheralConnection(old) }
        onStatus?(message, false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        guard running else { return }
        let task = DispatchWorkItem { [weak self] in self?.discover() }
        reconnect = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running, central === self.central else { return }
        if central.state == .poweredOn { discover(); return }
        reset()
        reconnect?.cancel(); reconnect = nil
        switch central.state {
        case .unauthorized: onStatus?("请在系统设置中授权蓝牙访问", false)
        case .poweredOff: onStatus?("蓝牙已关闭，请开启蓝牙", false)
        case .unsupported: onStatus?("这台 Mac 不支持所需的蓝牙连接", false)
        default: onStatus?("蓝牙暂时不可用", false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running, central === self.central, self.peripheral == nil else { return }
        let name = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = ["mi rc", "xiaomi bluetooth remote 2 pro", "小米蓝牙语音遥控器"]
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard names.contains(name) || services.contains(service) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running, central === self.central, self.peripheral === peripheral else { central.cancelPeripheralConnection(peripheral); return }
        onStatus?("正在初始化语音…", false)
        setTimeout("语音初始化超时，请重新连接", seconds: 8)
        peripheral.discoverServices([service, batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard running, central === self.central, self.peripheral === peripheral else { return }
        fail("无法连接遥控器，请确认已在 macOS 蓝牙设置中配对")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard running, central === self.central, self.peripheral === peripheral else { return }
        VoiceDiagnostics.logger.error("Bluetooth disconnected: \(error?.localizedDescription ?? "no_error", privacy: .public)")
        reset()
        onStatus?("遥控器已断开，正在重连…", false)
        scheduleReconnect()
    }

    fileprivate func discoveredServices(_ peripheral: CBPeripheral, error: Error?) {
        guard error == nil, let services = peripheral.services, services.contains(where: { $0.uuid == service }) else {
            fail("该设备未提供兼容的遥控器语音服务"); return
        }
        for item in services {
            if item.uuid == service { peripheral.discoverCharacteristics([txID, audioID, controlID], for: item) }
            if item.uuid == batteryService { peripheral.discoverCharacteristics([batteryID], for: item) }
        }
    }

    fileprivate func discoveredCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard error == nil else {
            if service.uuid == self.service { fail("无法读取遥控器语音服务") }
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case txID:
                guard !characteristic.properties.intersection([.write, .writeWithoutResponse]).isEmpty else {
                    fail("遥控器不支持所需语音命令"); return
                }
                transmit = characteristic
            case audioID, controlID:
                guard !characteristic.properties.intersection([.notify, .indicate]).isEmpty else {
                    fail("遥控器不支持语音通知"); return
                }
                peripheral.setNotifyValue(true, for: characteristic)
            case batteryID:
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
            default: break
            }
        }
        requestCapabilities()
    }

    fileprivate func notificationChanged(_ characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == audioID || characteristic.uuid == controlID else { return }
        guard error == nil, characteristic.isNotifying else { fail("无法订阅遥控器语音，请重新连接"); return }
        subscribed.insert(characteristic.uuid)
        requestCapabilities()
    }

    private func requestCapabilities() {
        guard !requestedCapabilities, transmit != nil, subscribed.contains(audioID), subscribed.contains(controlID) else { return }
        requestedCapabilities = true
        write(ATVVProtocol.getCapabilitiesV10)
    }

    private func write(_ data: Data) {
        guard let peripheral, let transmit else { return }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: transmit, type: type)
    }

    func closeMicrophone() {
        if let capabilities { write(ATVVProtocol.microphoneClose(version: capabilities.version, sessionID: sessionID)) }
        stopStreaming(reason: "microphone_close")
    }

    private func startStreaming() {
        guard !streaming else { return }
        decoder.reset(); accumulator.reset(); pendingSync = nil
        streaming = true
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        receivedSamples = 0
        VoiceDiagnostics.logger.info("Remote stream started: session=\(self.sessionID)")
        lastStop = nil
        if let capabilities, ATVVProtocol.microphoneExtend(version: capabilities.version, sessionID: sessionID) != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.streaming, let capabilities = self.capabilities,
                      let command = ATVVProtocol.microphoneExtend(version: capabilities.version, sessionID: self.sessionID) else { return }
                guard self.shouldOpenMicrophone?() == true else { self.closeMicrophone(); return }
                self.write(command)
            }
            microphoneKeepAlive = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        onVoice?(true)
    }

    private func stopStreaming(reason: String) {
        if streaming {
            let duration = max(0, ProcessInfo.processInfo.systemUptime - (streamStartedAt ?? ProcessInfo.processInfo.systemUptime))
            VoiceDiagnostics.logger.info("Remote stream stopped: reason=\(reason, privacy: .public) session=\(self.sessionID) duration_s=\(duration) samples=\(self.receivedSamples) partial_bytes=\(self.accumulator.pending.count)")
        }
        streamStartedAt = nil
        microphoneKeepAlive?.invalidate(); microphoneKeepAlive = nil
        let wasStreaming = streaming
        streaming = false
        accumulator.reset(); pendingSync = nil
        lastStop = ProcessInfo.processInfo.systemUptime
        if wasStreaming { onVoice?(false) }
    }

    fileprivate func received(_ characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            if characteristic.uuid != batteryID { fail("遥控器语音连接中断，正在重连…") }
            return
        }
        guard let data = characteristic.value, !data.isEmpty else {
            VoiceDiagnostics.logger.debug("Ignored empty Bluetooth notification")
            return
        }
        if characteristic.uuid == batteryID {
            battery = data.first.map { min(100, Int($0)) }
            onDevice?(peripheral?.name ?? "小米蓝牙遥控器", battery)
        } else if characteristic.uuid == controlID { handleControl(data) }
        else if characteristic.uuid == audioID, isReady, shouldOpenMicrophone?() == true {
            guard lastStop.map({ ProcessInfo.processInfo.systemUptime - $0 >= 0.3 }) ?? true else { return }
            startStreaming()
            guard let capabilities else { return }
            for frame in accumulator.append(data, frameSize: capabilities.frameSize) {
                if let (predictor, index) = pendingSync { decoder.reset(predictor: predictor, stepIndex: index); pendingSync = nil }
                let samples = decoder.decode(frame)
                receivedSamples += samples.count
                onSamples?(samples)
            }
        }
    }

    private func handleControl(_ data: Data) {
        let bytes = Array(data)
        switch bytes[0] {
        case 0x0B:
            guard requestedCapabilities, !isReady, let parsed = ATVVCapabilities.parse(data), parsed.sampleRate == 16_000,
                  parsed.frameSize > 0, parsed.frameSize <= 4096 else {
                if !isReady { fail("遥控器未提供受支持的语音格式") }
                return
            }
            capabilities = parsed
            isReady = true
            timeout?.cancel(); timeout = nil
            if let peripheral {
                cachedID = peripheral.identifier
                onReady?(peripheral.identifier)
            }
            onStatus?("已连接", true)
        case 0x08:
            guard isReady, let capabilities, shouldOpenMicrophone?() == true else { closeMicrophone(); return }
            write(ATVVProtocol.microphoneOpen(version: capabilities.version, codec: capabilities.selectedCodec))
        case 0x04:
            guard isReady, shouldOpenMicrophone?() == true else { closeMicrophone(); return }
            guard bytes.count < 3 || bytes[2] == 0x02 else { fail("遥控器切换到了不支持的语音格式"); return }
            sessionID = bytes.count >= 4 ? bytes[3] : 0
            VoiceDiagnostics.logger.info("Remote start notification: session=\(self.sessionID)")
            startStreaming()
        case 0x00: stopStreaming(reason: "remote_stop")
        case 0x0A:
            guard isReady, bytes.count >= 7 else { return }
            pendingSync = (Int(Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5]))), Int(bytes[6]))
            accumulator.reset()
        default: break
        }
    }
}
