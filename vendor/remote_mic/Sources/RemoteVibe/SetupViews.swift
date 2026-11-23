import AppKit
import SwiftUI
import CoreBluetooth

// SayAll's native panel treatment, with a macOS 13–15 material fallback.
struct SettingsPanel<Content: View>: View {
    let title: String
    let icon: String
    private let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty { Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
    private var materialPanel: some View {
        panelContent
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1))
    }
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            panelContent.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else { materialPanel }
        #else
        materialPanel
        #endif
    }
}

struct RemoteConnectionControls: View {
    @ObservedObject var model: AppModel
    var showsPhoto = true
    var body: some View {
        VStack(spacing: 16) {
            if showsPhoto {
                RemotePhoto().frame(width: 118, height: 240).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(model.deviceName).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Label(model.connectionStatus, systemImage: model.connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.connected ? Color.green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let battery = model.battery {
                Label("\(battery)%", systemImage: battery < 20 ? "battery.25percent" : "battery.75percent")
                    .foregroundStyle(battery < 20 ? Color.orange : .secondary)
            }
            HStack {
                Button(model.connecting ? "重新连接" : "连接遥控器") { model.connect() }.buttonStyle(.borderedProminent)
                if model.connecting { Button("断开蓝牙") { model.disconnect() }.buttonStyle(.bordered) }
            }
            Button("打开蓝牙设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }
            Text("先在系统蓝牙设置中配对。请退出 SayAll 等其他遥控器工具，避免占用同一设备。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AudioSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsPanel("音频输入", icon: "mic") {
            Picker("麦克风", selection: $model.settings.microphoneSource) {
                ForEach(MicrophoneSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if model.settings.microphoneSource == .mac {
                Picker("输入设备", selection: $model.settings.inputDeviceUID) {
                    Text("沿用系统默认").tag("")
                    if !model.settings.inputDeviceUID.isEmpty && !model.devices.contains(where: { $0.id == model.settings.inputDeviceUID }) {
                        Text("已保存的设备（未连接）").tag(model.settings.inputDeviceUID)
                    }
                    ForEach(model.devices.filter(\.hasInput)) { Text($0.name).tag($0.id) }
                }
                Text("语音输入法直接使用 Mac 麦克风，RemoteVibe 不录音。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Picker("虚拟音频设备", selection: $model.settings.virtualDeviceUID) {
                    Text("选择设备").tag("")
                    if !model.settings.virtualDeviceUID.isEmpty && !model.virtualDevices.contains(where: { $0.id == model.settings.virtualDeviceUID }) {
                        Text("已保存的设备（未连接）").tag(model.settings.virtualDeviceUID)
                    }
                    ForEach(model.virtualDevices) { Text($0.name).tag($0.id) }
                }
                if model.virtualDevices.isEmpty {
                    Text("未找到虚拟音频设备。请先安装 BlackHole 2ch，或使用已有的 MiRemoteV 2ch。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.audioStatus).font(.system(size: 12)).foregroundStyle(model.audioReady ? Color.green : .secondary)
                HStack {
                    Text("麦克风增益")
                    Slider(value: $model.settings.gainDB, in: 0...24, step: 1)
                    Text("\(Int(model.settings.gainDB)) dB").monospacedDigit().frame(width: 45)
                }
                Button("重新连接音频") { model.configureAudio() }
                Text("在输入法中选择同一虚拟麦克风。按住遥控器语音键说话，松开结束。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("刷新设备") { model.refreshDevices() }
                Button("设为系统默认输入") { model.applyDefaultInput() }
                    .help("会改变所有使用系统默认麦克风的应用。")
            }
        }
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var model: AppModel
    var showsTestButton = true
    private var choices: [String] {
        let choices = Configuration.inputMethods
        return choices.contains(model.settings.inputMethod) ? choices : choices + [model.settings.inputMethod]
    }
    var body: some View {
        SettingsPanel("语音输入法", icon: "waveform") {
            Picker("语音输入法", selection: $model.settings.inputMethod) {
                ForEach(choices, id: \.self) { Text($0.isEmpty ? "未选择" : $0).tag($0) }
            }.pickerStyle(.menu)
            HStack {
                Text("语音快捷键")
                Spacer()
                ShortcutRecorder(value: $model.settings.voiceShortcut)
            }
            Picker("输入法的触发方式", selection: $model.settings.voiceTrigger) {
                ForEach(VoiceTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("快捷键和触发方式需与输入法设置一致。支持组合键、Control + Command 等修饰键以及单独 Fn。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showsTestButton {
                Button(model.voicePhase == .idle ? "测试语音快捷键" : "结束语音") { model.toggleVoiceTest() }
                    .disabled(model.voicePhase == .stopping)
            }
        }
    }
}

struct PermissionSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsPanel("连接和控制权限", icon: "shield.lefthalf.filled") {
            row("蓝牙", detail: "连接遥控器并接收语音。", icon: "antenna.radiowaves.left.and.right", granted: model.bluetoothAuthorization == .allowedAlways) {
                if model.bluetoothAuthorization == .notDetermined { model.connect() }
                else { model.openPrivacy("Privacy_Bluetooth") }
            }
            Divider()
            row("输入监控", detail: "只监听已匹配的小米遥控器。", icon: "keyboard", granted: model.inputGranted) {
                if !model.inputGranted { model.requestInputMonitoring() }
                model.openPrivacy("Privacy_ListenEvent")
            }
            Divider()
            row("辅助功能", detail: "发送按键和语音快捷键。", icon: "accessibility", granted: model.accessibilityGranted) {
                if !model.accessibilityGranted { model.requestAccessibility() }
                model.openPrivacy("Privacy_Accessibility")
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal").font(.system(size: 19)).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text("自动化").fontWeight(.semibold)
                    Text("首次控制 iTerm2 时由系统请求。被拒绝后可在这里重新授权。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("打开设置") { model.openPrivacy("Privacy_Automation") }
            }
            Button("刷新权限状态") { model.refreshPermissions() }
        }
    }
    private func row(_ title: String, detail: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                Label(granted ? "已授权" : "未授权", systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12)).foregroundStyle(granted ? Color.green : .secondary)
            }
            Spacer(minLength: 4)
            Button(granted ? "打开设置" : "授权") { action() }
        }
    }
}

struct RuntimeStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.loadError ?? model.persistenceError {
                Text(error).foregroundStyle(.red)
                if model.loadError != nil {
                    Button("备份原文件并重置配置") { model.resetUnreadableSettings() }
                } else {
                    Button("重试保存") { model.retrySavingConfiguration() }
                }
            }
            Text(model.message).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
