import AppKit
import IOKit.hid

// Adapted from SayAll RemoteButtons.swift, GPL-3.0-only.
enum RemoteReportParser {
    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }
        var bytes = Array(data)
        if bytes.count == 7, bytes.first == UInt8(reportID) { bytes.removeFirst() }
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        var result = Set<UInt16>()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if usage != 0 { result.insert(usage) }
        }
        return result
    }
}

final class RemoteInput {
    var onStatus: ((String) -> Void)?
    var onButton: ((RemoteButton, Bool) -> Void)?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let suppressor = KeyboardEventSuppressor()
    private var shared = false
    private var pressed = Set<UInt16>()
    var isRunning: Bool { manager != nil }
    var isConnected: Bool { device != nil }

    static var hasPermission: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    func start() {
        guard manager == nil else { return }
        guard Self.hasPermission, AXIsProcessTrusted() else {
            onStatus?("请先授权输入监控和辅助功能"); return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // 与上游相同的严格设备匹配，不监听普通键盘。
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x2717, kIOHIDProductIDKey: 0x32B8] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<RemoteInput>.fromOpaque(context).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let input = Unmanaged<RemoteInput>.fromOpaque(context).takeUnretainedValue()
            if let active = input.device, CFEqual(active, device) {
                input.releaseButtons()
                IOHIDDeviceClose(active, IOOptionBits(kIOHIDOptionsTypeNone))
                input.device = nil
                input.suppressor.stop()
                input.shared = false
                input.onStatus?("遥控器已断开，等待重新连接")
            }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, _, reportID, report, length in
            guard let context, let sender, result == kIOReturnSuccess, length > 0 else { return }
            let input = Unmanaged<RemoteInput>.fromOpaque(context).takeUnretainedValue()
            let source = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            guard let active = input.device, CFEqual(active, source),
                  let usages = RemoteReportParser.usages(reportID: reportID, data: Data(bytes: report, count: length)) else { return }
            input.handle(usages)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            stop(); onStatus?("无法监听遥控器，请检查输入监控权限（\(status)）")
        } else if device == nil { onStatus?("等待已配对的小米遥控器") }
    }

    private func matched(_ candidate: IOHIDDevice) {
        guard device == nil else { return }
        let page = (IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
        let usage = (IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
        guard page == 1, usage == 6 else { return }
        let seizeStatus = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        let status = seizeStatus == kIOReturnSuccess ? seizeStatus : IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            switch status {
            case kIOReturnNotPrivileged, kIOReturnNotPermitted:
                onStatus?("系统拒绝读取遥控器，请检查输入监控权限（独占 \(seizeStatus)，共享 \(status)）")
            case kIOReturnExclusiveAccess:
                onStatus?("遥控器被占用，请退出其他 RemoteVibe 实例、SayAll 或其他遥控器工具后重试（\(status)）")
            default:
                onStatus?("无法独占遥控器，请断开并重新连接遥控器后重试（\(status)）")
            }
            return
        }
        shared = seizeStatus != kIOReturnSuccess
        if shared && !suppressor.start() {
            shared = false
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            onStatus?("无法开启遥控器原生按键过滤，已停止接管，请检查辅助功能权限后重试")
            return
        }
        device = candidate
        onStatus?(shared ? "按键已连接（共享兼容模式）" : "按键已连接")
    }

    private func handle(_ usages: Set<UInt16>) {
        let released = pressed.subtracting(usages)
        let began = usages.subtracting(pressed)
        pressed = usages
        // Arm every physical edge before any action can inject synthetic keys.
        if shared {
            for button in RemoteButton.allCases where released.contains(button.usage) { suppressor.arm(button, down: false) }
            for button in RemoteButton.allCases where began.contains(button.usage) { suppressor.arm(button, down: true) }
        }
        for button in RemoteButton.allCases where released.contains(button.usage) { onButton?(button, false) }
        for button in RemoteButton.allCases where began.contains(button.usage) { onButton?(button, true) }
    }

    private func releaseButtons() {
        let old = pressed
        pressed.removeAll()
        for button in RemoteButton.allCases where old.contains(button.usage) { onButton?(button, false) }
    }

    func stop() {
        releaseButtons()
        suppressor.stop()
        shared = false
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        onStatus?("按键映射已关闭")
    }
}

// 重复发送完整的按下/松开，不留下需要后续释放的合成按键。
final class KeyRepeater {
    private var timer: Timer?
    private(set) var generation = UUID()

    func start(delay: TimeInterval = 0.4, interval: TimeInterval = 0.05, action: @escaping () -> Bool) {
        stop()
        let timer = Timer(fire: Date(timeIntervalSinceNow: delay), interval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !action() { self.stop() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
    }

    deinit { timer?.invalidate() }
}
