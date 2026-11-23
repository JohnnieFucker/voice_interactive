import AppKit

// Adapted from SayAll KeyboardEventSuppressor.swift, GPL-3.0-only.
// Shared HID mode cannot identify a physical device from a public CGEvent.
// Match only native events armed by the selected remote's HID report.
struct RemoteNativeEvent: Hashable {
    let code: Int64
    let system: Bool

    static func events(for button: RemoteButton) -> Set<Self> {
        let codes: [RemoteButton: Int64] = [
            .power: 90, .voice: 96, .up: 126, .left: 123, .ok: 36,
            .right: 124, .down: 125, .home: 115, .menu: 110, .tv: 10
        ]
        if button == .volumeUp { return [Self(code: 0, system: true)] }
        if button == .volumeDown { return [Self(code: 1, system: true)] }
        guard let code = codes[button] else { return [] }
        let event = Self(code: code, system: false)
        return button == .tv ? [event, Self(code: 50, system: false)] : [event]
    }
}

struct RemoteEventFilter {
    private struct Pending {
        let event: RemoteNativeEvent
        let down: Bool
        let expires: TimeInterval
    }
    private var pending: [Pending] = []
    private var held = Set<RemoteNativeEvent>()

    mutating func arm(_ button: RemoteButton, down: Bool, now: TimeInterval) {
        pending.removeAll { $0.expires <= now }
        for event in RemoteNativeEvent.events(for: button) {
            if down { held.insert(event) }
            else { held.remove(event) }
            pending.append(Pending(event: event, down: down, expires: now + 0.18))
        }
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
    }

    mutating func suppress(_ event: RemoteNativeEvent, down: Bool, repeating: Bool, now: TimeInterval) -> Bool {
        pending.removeAll { $0.expires <= now }
        if let index = pending.firstIndex(where: { $0.event == event && $0.down == down }) {
            pending.remove(at: index)
            return true
        }
        return down && repeating && held.contains(event)
    }
}

final class KeyboardEventSuppressor {
    static let syntheticMarker: Int64 = 0x5256494245
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var filter = RemoteEventFilter()

    func start() -> Bool {
        if port != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<KeyboardEventSuppressor>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func arm(_ button: RemoteButton, down: Bool) {
        filter.arm(button, down: down, now: ProcessInfo.processInfo.systemUptime)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return false }
        let native: RemoteNativeEvent
        let down: Bool
        if type.rawValue == 14 {
            guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
            let state = (nsEvent.data1 & 0xFF00) >> 8
            guard state == 0xA || state == 0xB else { return false }
            native = RemoteNativeEvent(code: Int64((nsEvent.data1 >> 16) & 0xFFFF), system: true)
            down = state == 0xA
        } else {
            native = RemoteNativeEvent(code: event.getIntegerValueField(.keyboardEventKeycode), system: false)
            down = type == .keyDown
        }
        return filter.suppress(native, down: down,
                               repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                               now: ProcessInfo.processInfo.systemUptime)
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        filter = RemoteEventFilter()
    }
}
