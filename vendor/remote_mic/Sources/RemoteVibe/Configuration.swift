import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var code: UInt32
    var modifiers: UInt32
    var label: String
    var modifierOnly: Bool? = nil

    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        for (flag, mask) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] where flags.contains(flag) {
            modifiers |= UInt32(mask)
        }
        let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键 \(event.keyCode)"
        let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
        return Shortcut(code: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }

    static func fromModifiers(_ flags: NSEvent.ModifierFlags) -> Shortcut? {
        if flags == .function { return Shortcut(code: 63, modifiers: 0, label: "Fn / 🌐", modifierOnly: true) }
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let flags = flags.intersection(allowed)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var label = ""
        for (flag, mask, name) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
            modifiers |= UInt32(mask)
            label += name
        }
        return Shortcut(code: 0, modifiers: modifiers, label: label, modifierOnly: true)
    }

    var isValid: Bool {
        let supported = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        if modifierOnly == true && code == 63 && modifiers == 0 { return true }
        return code <= 127 && modifiers & ~supported == 0 && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    var flags: CGEventFlags {
        if modifierOnly == true && code == 63 && modifiers == 0 { return .maskSecondaryFn }
        var result: CGEventFlags = []
        for (mask, flag) in [(cmdKey, CGEventFlags.maskCommand), (controlKey, .maskControl), (optionKey, .maskAlternate), (shiftKey, .maskShift)] where modifiers & UInt32(mask) != 0 {
            result.insert(flag)
        }
        return result
    }
}

enum RemoteButton: String, CaseIterable, Codable, Identifiable {
    case power, voice, up, left, ok, right, down, back, home, menu, volumeUp, volumeDown, tv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .power: return "电源"
        case .voice: return "语音"
        case .up: return "上"
        case .left: return "左"
        case .ok: return "确定"
        case .right: return "右"
        case .down: return "下"
        case .back: return "返回"
        case .home: return "主页"
        case .menu: return "菜单"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        case .tv: return "电视"
        }
    }
    // 小米遥控器键盘报告中的 usage，来源见 THIRD_PARTY_NOTICES.md。
    var usage: UInt16 {
        switch self {
        case .power: return 0x66
        case .voice: return 0x3E
        case .up: return 0x52
        case .left: return 0x50
        case .ok: return 0x28
        case .right: return 0x4F
        case .down: return 0x51
        case .back: return 0xF1
        case .home: return 0x4A
        case .menu: return 0x65
        case .volumeUp: return 0x80
        case .volumeDown: return 0x81
        case .tv: return 0x35
        }
    }
}

enum ButtonAction: String, Codable, CaseIterable, Identifiable {
    case none, focus, previousWindow, nextWindow, previousPane, nextPane, voice, enter, escape, backspace, up, down, left, right, shortcut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "不执行动作"
        case .focus: return "激活 iTerm2"
        case .previousWindow: return "上一个独立窗口"
        case .nextWindow: return "下一个独立窗口"
        case .previousPane: return "上一个分屏"
        case .nextPane: return "下一个分屏"
        case .voice: return "激活 iTerm2 并语音输入"
        case .enter: return "回车"
        case .escape: return "Esc"
        case .backspace: return "退格"
        case .up: return "方向上"
        case .down: return "方向下"
        case .left: return "方向左"
        case .right: return "方向右"
        case .shortcut: return "自定义快捷键"
        }
    }
    var keyCode: CGKeyCode? {
        switch self {
        case .enter: return 36
        case .escape: return 53
        case .backspace: return 51
        case .up: return 126
        case .down: return 125
        case .left: return 123
        case .right: return 124
        default: return nil
        }
    }
}

struct ButtonBinding: Codable, Equatable {
    var action: ButtonAction
    var shortcut: Shortcut?
    static let defaults: [String: ButtonBinding] = [
        "power": .init(action: .escape), "voice": .init(action: .voice),
        "home": .init(action: .focus), "left": .init(action: .previousPane),
        "right": .init(action: .nextPane), "up": .init(action: .up),
        "down": .init(action: .down), "ok": .init(action: .enter),
        "back": .init(action: .backspace), "menu": .init(action: .none),
        "volumeUp": .init(action: .none), "volumeDown": .init(action: .none), "tv": .init(action: .none)
    ]
}

enum MicrophoneSource: String, Codable, CaseIterable {
    case mac, remote
    var title: String { self == .mac ? "Mac 麦克风" : "遥控器麦克风" }
}

enum VoiceTrigger: String, Codable, CaseIterable {
    case toggle, hold
    var title: String { self == .toggle ? "点按开始 / 停止" : "按住快捷键说话" }
}

struct Configuration: Codable, Equatable {
    static let inputMethods = ["系统听写", "微信输入法", "豆包", "Typeless", "其他"]
    var version = 4
    var inputMethod = "系统听写"
    var voiceShortcut: Shortcut?
    var inputDeviceUID = ""
    var virtualDeviceUID = ""
    var microphoneSource = MicrophoneSource.mac
    var voiceTrigger = VoiceTrigger.toggle
    var mappingEnabled = false
    var gainDB = 6.0
    var peripheralID: UUID?
    var buttonBindings = ButtonBinding.defaults
    var onboardingStep = OnboardingStep.welcome
    var onboardingComplete = false
    var onboardingVoiceVerified = false
    var onboardingControlsVerified = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case version, inputMethod, voiceShortcut, inputDeviceUID, virtualDeviceUID, microphoneSource, voiceTrigger, mappingEnabled, gainDB, peripheralID, buttonBindings, onboardingStep, onboardingComplete, onboardingVoiceVerified, onboardingControlsVerified
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= 4 else { throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "配置来自更新版本，未覆盖原文件") }
        inputMethod = try values.decodeIfPresent(String.self, forKey: .inputMethod) ?? inputMethod
        voiceShortcut = try values.decodeIfPresent(Shortcut.self, forKey: .voiceShortcut)
        guard voiceShortcut?.isValid != false else { throw DecodingError.dataCorruptedError(forKey: .voiceShortcut, in: values, debugDescription: "无效的语音快捷键") }
        inputDeviceUID = try values.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? ""
        virtualDeviceUID = try values.decodeIfPresent(String.self, forKey: .virtualDeviceUID) ?? ""
        microphoneSource = try values.decodeIfPresent(MicrophoneSource.self, forKey: .microphoneSource) ?? .mac
        voiceTrigger = try values.decodeIfPresent(VoiceTrigger.self, forKey: .voiceTrigger) ?? .toggle
        mappingEnabled = try values.decodeIfPresent(Bool.self, forKey: .mappingEnabled) ?? false
        let gain = try values.decodeIfPresent(Double.self, forKey: .gainDB) ?? gainDB
        gainDB = gain.isFinite ? min(24, max(0, gain)) : 6
        peripheralID = try values.decodeIfPresent(UUID.self, forKey: .peripheralID)
        if let bindings = try values.decodeIfPresent([String: ButtonBinding].self, forKey: .buttonBindings) {
            buttonBindings.merge(bindings) { _, new in new }
        }
        // 只升级旧版左右键的原始默认值，不改动其他按键和自定义快捷键。
        if version < 3 {
            for (button, oldAction, newAction) in [("left", ButtonAction.previousWindow, ButtonAction.previousPane), ("right", .nextWindow, .nextPane)] {
                if buttonBindings[button] == ButtonBinding(action: oldAction) {
                    buttonBindings[button] = ButtonBinding(action: newAction)
                }
            }
        }
        onboardingStep = try values.decodeIfPresent(OnboardingStep.self, forKey: .onboardingStep) ?? .welcome
        onboardingComplete = try values.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        onboardingVoiceVerified = try values.decodeIfPresent(Bool.self, forKey: .onboardingVoiceVerified) ?? false
        onboardingControlsVerified = try values.decodeIfPresent(Bool.self, forKey: .onboardingControlsVerified) ?? false
        guard buttonBindings.values.allSatisfy({ $0.shortcut?.isValid != false }) else {
            throw DecodingError.dataCorruptedError(forKey: .buttonBindings, in: values, debugDescription: "无效的按键快捷键")
        }
    }
}
