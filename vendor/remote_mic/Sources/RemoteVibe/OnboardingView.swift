import AppKit
import SwiftUI

struct RemoteVibeRootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.settings.onboardingComplete { SettingsView(model: model) }
            else { OnboardingView(model: model) }
        }
    }
}

// Two-column layout, phase header and native treatments adapted from SayAll.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    private let phases = ["准备", "设置", "试一试"]
    private var step: OnboardingStep { model.settings.onboardingStep }

    var body: some View {
        VStack(spacing: 0) {
            phaseHeader
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    leftPane.frame(width: max(520, geometry.size.width * 0.53))
                    rightPane
                }
            }
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 980, minHeight: 732)
        .onAppear { model.resumeSetup() }
    }

    private var phaseHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    Text(phase)
                        .font(.system(size: 14, weight: step.phase == index ? .semibold : .regular))
                        .foregroundStyle(step.phase == index ? Color.primary : .secondary)
                }
            }.frame(maxWidth: .infinity)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(Color.primary).frame(width: geometry.size.width * step.progress)
                }
            }
            .frame(height: 3).padding(.horizontal, 28)
        }
        .padding(.top, 12).frame(height: 76)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前阶段：\(phases[step.phase])")
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previous = step.previous {
                Button { model.enterSetupStep(previous) } label: {
                    Label("返回", systemImage: "arrow.left")
                        .frame(minWidth: 72, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.bottom, 16)
            } else { Color.clear.frame(height: 60).accessibilityHidden(true) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(step.title).font(.system(size: 30, weight: .bold)).tracking(-0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(step.detail).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 12) {
                RuntimeStatusView(model: model)
                HStack {
                    Spacer()
                    Button { model.advanceSetup() } label: {
                        Text(step == .welcome ? "开始设置" : step == .complete ? "开始使用" : "继续")
                            .font(.system(size: 14, weight: .semibold)).frame(minWidth: 118)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.setupCanContinue)
                }
            }.padding(.top, 18)
        }
        .padding(.top, 24).padding(.horizontal, 48).padding(.bottom, 28)
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                feature("mic", "按住说话，松开结束")
                feature("rectangle.split.2x1", "用左右键切换 iTerm2 分屏")
                feature("checkmark.shield", "现场确认每一步都能工作")
            }.padding(.top, 16)
        case .permissions:
            PermissionSettingsView(model: model)
        case .remote:
            SettingsPanel("小米蓝牙遥控器", icon: "appletvremote.gen4") {
                RemoteConnectionControls(model: model, showsPhoto: false)
                Divider()
                Toggle("启用按键映射", isOn: $model.settings.mappingEnabled).toggleStyle(.switch)
                Text(model.inputStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("重新检测按键") { model.retryInput() }
            }
        case .audio:
            AudioSettingsView(model: model)
        case .voiceTool:
            VoiceSettingsView(model: model, showsTestButton: false)
        case .voiceTest:
            SettingsPanel("在 iTerm2 中试说一句", icon: "waveform") {
                check("启动快捷键已发送", ready: model.setupVoiceStarted)
                if model.settings.microphoneSource == .remote { check("已收到遥控器声音", ready: model.setupAudioReceived) }
                check("停止快捷键已发送", ready: model.setupVoiceStopped)
                Divider()
                Toggle("我已在 iTerm2 中看到正确的文字，且语音已停止", isOn: $model.settings.onboardingVoiceVerified)
                    .disabled(!model.setupVoiceReady)
                Text("松开语音键并等待语音结束后，再回到这个窗口确认。应用不会按回车或读取你的终端内容。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.settings.microphoneSource == .mac && model.settings.buttonBindings["voice"]?.action != .voice {
                    Button("将语音键设为语音输入") { model.settings.buttonBindings["voice"] = .init(action: .voice) }
                }
                Button("打开 iTerm2") { model.perform(.init(action: .focus)) }
            }
        case .controls:
            SettingsPanel("左右切换分屏", icon: "rectangle.split.2x1") {
                check("左键：上一个分屏", ready: model.setupTestedButtons.contains(.left))
                check("右键：下一个分屏", ready: model.setupTestedButtons.contains(.right))
                if model.settings.buttonBindings["left"]?.action != .previousPane || model.settings.buttonBindings["right"]?.action != .nextPane {
                    Button("将左右键设为切换分屏") {
                        model.settings.buttonBindings["left"] = .init(action: .previousPane)
                        model.settings.buttonBindings["right"] = .init(action: .nextPane)
                    }
                }
                Divider()
                Toggle("我已确认两个按键都切换到了正确的分屏", isOn: $model.settings.onboardingControlsVerified)
                    .disabled(!model.setupControlsReady)
                Text("使用 iTerm2 的分屏功能创建会话。终端内部的 tmux 分屏需要单独设置快捷键。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("打开 iTerm2") { model.perform(.init(action: .focus)) }
            }
        case .complete:
            VStack(alignment: .leading, spacing: 16) {
                check("遥控器已连接", ready: model.connected && model.inputConnected)
                check("语音输入已由你确认", ready: model.settings.onboardingVoiceVerified)
                check("分屏切换已由你确认", ready: model.settings.onboardingControlsVerified)
                if !model.connected || !model.inputConnected { Button("重新连接遥控器") { model.connect() } }
            }
        }
    }

    private var rightPane: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: rightColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.55))
                    .frame(width: 360, height: 360).blur(radius: 10).offset(x: 110, y: -110)
                    .accessibilityHidden(true)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        if step == .voiceTool { inputMethodGuide }
                        else if step == .complete { completionIllustration }
                        else {
                            RemotePhoto().frame(width: 220, height: 447).clipShape(RoundedRectangle(cornerRadius: 14))
                            rightStatus
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 56), alignment: .center)
                    .padding(.horizontal, 28).padding(.vertical, 28)
                }
            }.clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rightColors: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.10, green: 0.13, blue: 0.18), Color(red: 0.13, green: 0.15, blue: 0.20)]
            : [Color(red: 0.91, green: 0.96, blue: 1), Color(red: 0.97, green: 0.98, blue: 1)]
    }

    private var rightStatus: some View {
        SettingsPanel(step == .welcome ? "小米遥控器 × iTerm2" : "当前状态", icon: "appletvremote.gen4") {
            if step == .welcome {
                Text("让说话和切换会话，变得顺手。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                check(model.connectionStatus, ready: model.connected)
                check(model.inputStatus, ready: model.inputConnected)
                if step == .audio || step == .voiceTest {
                    check(model.settings.microphoneSource.title, ready: model.setupAudioReady)
                }
            }
        }.frame(maxWidth: 360)
    }

    private var inputMethodGuide: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform").font(.system(size: 64, weight: .medium)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(model.settings.inputMethod).font(.system(size: 23, weight: .semibold))
            SettingsPanel("先在输入法中设置", icon: "keyboard") {
                guideLine("打开语音输入功能，并设定启动、停止快捷键。")
                guideLine("确认采用点按切换，还是按住说话。")
                guideLine(model.settings.microphoneSource == .remote ? "将麦克风选为同一个虚拟音频设备。" : "确认麦克风是你选择的 Mac 输入设备。")
            }
            Text("再回到左侧录制相同快捷键。下一步会在 iTerm2 中做一次真实输入测试。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 360)
    }

    private var completionIllustration: some View {
        VStack(spacing: 28) {
            Image(systemName: model.setupCanContinue ? "checkmark.circle.fill" : "appletvremote.gen4")
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(model.setupCanContinue ? Color.accentColor : .secondary).accessibilityHidden(true)
            Text(model.setupCanContinue ? "随手一按，继续创造。" : "恢复连接后，继续创造。")
                .font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
            Text("主页：\(model.settings.buttonBindings["home"]?.action.title ?? "未设置")\n左右切换分屏\n按住语音键说话")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(10)
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        Label { Text(text).font(.system(size: 14, weight: .medium)) } icon: {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor).frame(width: 26)
        }
    }
    private func guideLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.right").foregroundStyle(Color.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func check(_ text: String, ready: Bool) -> some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13)).foregroundStyle(ready ? Color.green : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
