import Foundation

// Layout and journey adapted from SayAll OnboardingFlow / OnboardingView.
enum OnboardingStep: String, Codable, CaseIterable {
    case welcome, permissions, remote, audio, voiceTool, voiceTest, controls, complete

    var previous: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
    var next: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }
    var progress: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0) / Double(Self.allCases.count - 1)
    }
    var phase: Int {
        switch self {
        case .welcome: return 0
        case .permissions, .remote, .audio, .voiceTool: return 1
        case .voiceTest, .controls, .complete: return 2
        }
    }
    func allowsPhysicalAction(_ button: RemoteButton) -> Bool {
        switch self {
        case .voiceTest: return button == .voice
        case .controls: return button == .left || button == .right
        default: return false
        }
    }
    var title: String {
        switch self {
        case .welcome: return "把遥控器变成\n你的编程控制器"
        case .permissions: return "允许连接和控制 Mac"
        case .remote: return "连接你的小米遥控器"
        case .audio: return "选择声音从哪里来"
        case .voiceTool: return "设置你常用的语音工具"
        case .voiceTest: return "说一句，试试看"
        case .controls: return "再试试切换分屏"
        case .complete: return "准备好了，开始编程"
        }
    }
    var detail: String {
        switch self {
        case .welcome: return "用遥控器切换 iTerm2 分屏、按住说话，让想法直接进入当前会话。"
        case .permissions: return "只需要蓝牙、输入监控和辅助功能。第一次控制 iTerm2 时，系统还会请求自动化权限。"
        case .remote: return "先在 macOS 蓝牙设置中配对，按任意键唤醒遥控器，再连接。"
        case .audio: return "可以使用 Mac 麦克风，也可以把遥控器变成无线麦克风。"
        case .voiceTool: return "选择语音输入法，并录制与输入法设置相同的语音快捷键。"
        case .voiceTest: return "先打开一个 iTerm2 会话，按住遥控器语音键，说一句“你好，开始编程”，再松开。不要按确定键。"
        case .controls: return "在同一 iTerm2 标签页中垂直拆分至少两个分屏，分别按一下遥控器的左键和右键。"
        case .complete: return "连接、按键与语音设置已完成。以后可从菜单栏打开设置，也能重新运行配置向导。"
        }
    }
}
