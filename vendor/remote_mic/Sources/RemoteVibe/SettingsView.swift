import SwiftUI
import AppKit
import CoreBluetooth

private enum SettingsPage: String, CaseIterable, Identifiable {
    case connection, buttons, permissions
    var id: String { rawValue }
    var title: String {
        switch self { case .connection: return "连接与语音"; case .buttons: return "按键配置"; case .permissions: return "权限" }
    }
    var icon: String {
        switch self { case .connection: return "link"; case .buttons: return "keyboard"; case .permissions: return "shield.lefthalf.filled" }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page = SettingsPage.connection
    @State private var selectedButton = RemoteButton.left
    @State private var editorRequest = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(page.title).font(.system(size: 25, weight: .semibold))
                    Spacer()
                    Text(model.loadError == nil && model.persistenceError == nil ? "配置自动保存" : "配置未保存").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                    Group {
                        switch page {
                        case .connection: connectionPage
                        case .buttons: buttonsPage
                        case .permissions: permissionsPage
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                    .onChange(of: editorRequest) { _ in proxy.scrollTo("action-editor", anchor: .top) }
                }
                Divider()
                RuntimeStatusView(model: model)
                    .padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 980, minHeight: 732)
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            Text("RemoteVibe").font(.system(size: 16, weight: .semibold)).padding(.top, 24).padding(.bottom, 22)
            ForEach(SettingsPage.allCases) { item in
                Button { page = item } label: {
                    VStack(spacing: 8) {
                        Image(systemName: item.icon).font(.system(size: 22, weight: .medium))
                        Text(item.title).font(.system(size: 12, weight: page == item ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity).frame(height: 72)
                    .background(RoundedRectangle(cornerRadius: 10).fill(page == item ? Color.accentColor.opacity(0.12) : .clear))
                    .foregroundStyle(page == item ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer()
            Button { model.restartSetup() } label: {
                VStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 19))
                    Text("配置向导").font(.system(size: 12))
                }
                .frame(maxWidth: .infinity).frame(height: 68).contentShape(Rectangle())
            }.buttonStyle(.plain).help("重新运行首次配置，保留现有设置。")
        }
        .padding(.horizontal, 8)
        .frame(width: 108)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var connectionPage: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsPanel("遥控器", icon: "appletvremote.gen4") {
                RemoteConnectionControls(model: model)
            }.frame(width: 230)
            VStack(spacing: 14) {
                AudioSettingsView(model: model)
                VoiceSettingsView(model: model)
            }.frame(maxWidth: .infinity)
        }
    }

    private var buttonsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Toggle("启用按键映射", isOn: $model.settings.mappingEnabled).toggleStyle(.switch)
                Spacer()
                Text(model.inputStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("重新检测") { model.retryInput() }
            }
            RemoteMappingCanvas(
                selected: $selectedButton, pressed: model.pressed,
                bindings: model.settings.buttonBindings,
                remoteVoice: model.settings.microphoneSource == .remote
            ) { button in
                selectedButton = button
                editorRequest += 1
            }
            SettingsPanel("\(selectedButton.title)键", icon: "keyboard") {
                VStack(alignment: .leading, spacing: 18) {
                    if model.pressed.contains(selectedButton) {
                        Label("正在按下", systemImage: "circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                    if selectedButton == .voice && model.settings.microphoneSource == .remote {
                        Label("按住语音输入，松开结束", systemImage: "mic.fill")
                        Text("使用遥控器麦克风时保留实体语音键，其余按键可自定义。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        actionGroup("iTerm2", actions: [.focus, .previousPane, .nextPane, .previousWindow, .nextWindow, .voice])
                        actionGroup("键盘", actions: [.enter, .escape, .backspace, .up, .down, .left, .right])
                        actionGroup("自定义", actions: [.shortcut, .none])
                        if selectedBinding.action == .shortcut {
                            HStack {
                                Text("快捷键")
                                Spacer()
                                ShortcutRecorder(value: Binding(get: { selectedBinding.shortcut }, set: { new in
                                    var binding = selectedBinding
                                    binding.shortcut = new
                                    model.settings.buttonBindings[selectedButton.rawValue] = binding
                                }))
                            }
                        }
                        Divider()
                        HStack {
                            Text("当前：\(selectedBinding.action.title)").foregroundStyle(.secondary)
                            Spacer()
                            Button("测试这个动作") { model.perform(selectedBinding) }
                                .disabled(selectedBinding.action == .none)
                        }
                    }
                    Text("左、右默认循环切换当前标签页的分屏；独立窗口有单独的切换动作。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.id("action-editor")
        }
    }

    private var selectedBinding: ButtonBinding { model.settings.buttonBindings[selectedButton.rawValue] ?? .init(action: .none) }

    private func actionGroup(_ title: String, actions: [ButtonAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        var binding = selectedBinding
                        binding.action = action
                        model.settings.buttonBindings[selectedButton.rawValue] = binding
                    } label: {
                        Text(action.title)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedBinding.action == action ? Color.accentColor : nil)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(selectedBinding.action == action ? Color.accentColor : .clear, lineWidth: 1))
                    .disabled(action == .voice && model.settings.microphoneSource == .remote)
                    .accessibilityAddTraits(selectedBinding.action == action ? .isSelected : [])
                }
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            PermissionSettingsView(model: model)
            Text("不保存录音、识别文本或操作历史，不上传使用统计。语音识别由你配置的输入法处理。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct RemotePhoto: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "RC003-remote-photo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text("遥控器图片未找到，请重新打包应用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RemoteDiagram: View {
    @Binding var selected: RemoteButton
    let pressed: Set<RemoteButton>
    let bindings: [String: ButtonBinding]
    // SayAll RemoteMappingCanvas 的图片坐标，使用相同宽高比例和填充方式。
    static let anchors: [RemoteButton: UnitPoint] = [
        .power: .init(x: 0.386, y: 0.099), .voice: .init(x: 0.630, y: 0.099),
        .up: .init(x: 0.502, y: 0.179), .left: .init(x: 0.362, y: 0.246),
        .ok: .init(x: 0.502, y: 0.246), .right: .init(x: 0.638, y: 0.246),
        .down: .init(x: 0.502, y: 0.317), .back: .init(x: 0.406, y: 0.389),
        .home: .init(x: 0.406, y: 0.479), .menu: .init(x: 0.406, y: 0.569),
        .volumeUp: .init(x: 0.604, y: 0.390), .volumeDown: .init(x: 0.604, y: 0.480),
        .tv: .init(x: 0.604, y: 0.569)
    ]
    var width: CGFloat = 251
    var onSelect: (RemoteButton) -> Void = { _ in }
    private var height: CGFloat { width * 510 / 251 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemotePhoto()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            ForEach(RemoteButton.allCases) { button in
                if let anchor = Self.anchors[button] {
                    Button { selected = button; onSelect(button) } label: {
                        Circle()
                            .fill(pressed.contains(button) ? Color.accentColor.opacity(0.35) : .clear)
                            .overlay(Circle().stroke(selected == button ? Color.accentColor : .clear, lineWidth: 2))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: width * anchor.x, y: height * anchor.y)
                    .accessibilityLabel("\(button.title)键，\(bindings[button.rawValue]?.action.title ?? "未设置")")
                    .accessibilityAddTraits(selected == button ? .isSelected : [])
                    .help(button.title)
                }
            }
        }
        .frame(width: width, height: height)
    }
}

private struct MappingPlacement: Identifiable {
    let button: RemoteButton
    let left: Bool
    let y: CGFloat
    var id: RemoteButton { button }
}

private struct RemoteMappingCanvas: View {
    @Binding var selected: RemoteButton
    let pressed: Set<RemoteButton>
    let bindings: [String: ButtonBinding]
    let remoteVoice: Bool
    let onEdit: (RemoteButton) -> Void
    // Original SayAll arrangement, with only one editable action per physical key.
    private static let placements: [MappingPlacement] = [
        .init(button: .power, left: true, y: 0.08), .init(button: .up, left: true, y: 0.23),
        .init(button: .left, left: true, y: 0.38), .init(button: .back, left: true, y: 0.53),
        .init(button: .home, left: true, y: 0.68), .init(button: .menu, left: true, y: 0.83),
        .init(button: .voice, left: false, y: 0.07), .init(button: .right, left: false, y: 0.215),
        .init(button: .ok, left: false, y: 0.36), .init(button: .down, left: false, y: 0.505),
        .init(button: .volumeUp, left: false, y: 0.65), .init(button: .volumeDown, left: false, y: 0.795),
        .init(button: .tv, left: false, y: 0.94)
    ]
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let cardWidth = min(260, max(190, (width - 299) / 2))
            ZStack {
                RemoteDiagram(selected: $selected, pressed: pressed, bindings: bindings, onSelect: onEdit)
                    .position(x: width / 2, y: 285)
                Canvas { context, _ in
                    for placement in Self.placements {
                        guard let anchor = RemoteDiagram.anchors[placement.button] else { continue }
                        let start = CGPoint(x: width / 2 - 125.5 + 251 * anchor.x, y: 30 + 510 * anchor.y)
                        let end = CGPoint(x: placement.left ? cardWidth + 7 : width - cardWidth - 7, y: 570 * placement.y)
                        let direction: CGFloat = placement.left ? -1 : 1
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end,
                                      control1: CGPoint(x: start.x + direction * 50, y: start.y),
                                      control2: CGPoint(x: end.x - direction * 30, y: end.y))
                        let color = selected == placement.button ? Color.accentColor : Color.secondary.opacity(0.42)
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: selected == placement.button ? 1.6 : 1, lineCap: .round))
                        var arrow = Path()
                        arrow.move(to: end)
                        arrow.addLine(to: CGPoint(x: end.x - direction * 6, y: end.y - 4))
                        arrow.addLine(to: CGPoint(x: end.x - direction * 6, y: end.y + 4))
                        arrow.closeSubpath()
                        context.fill(arrow, with: .color(color))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(Self.placements) { placement in
                    actionCard(placement.button)
                        .frame(width: cardWidth, height: 58)
                        .position(x: placement.left ? cardWidth / 2 : width - cardWidth / 2, y: 570 * placement.y)
                }
            }
        }.frame(height: 570)
    }
    private func actionCard(_ button: RemoteButton) -> some View {
        let binding = bindings[button.rawValue] ?? .init(action: .none)
        let summary = button == .voice && remoteVoice ? "按住语音输入" : binding.action == .shortcut ? (binding.shortcut?.label ?? "录制快捷键") : binding.action.title
        return Button { selected = button; onEdit(button) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(button.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    if pressed.contains(button) { Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor) }
                }
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(selected == button ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == button ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(button.title)键，\(summary)")
        .accessibilityAddTraits(selected == button ? .isSelected : [])
    }
}

struct ShortcutRecorder: View {
    @Binding var value: Shortcut?
    @State private var monitor: Any?
    @State private var recordedModifiers: NSEvent.ModifierFlags = []
    var body: some View {
        HStack(spacing: 8) {
            Button(monitor == nil ? (value?.label ?? "录制快捷键") : "请按快捷键（支持 Fn），Esc 取消") {
                guard monitor == nil else { stop(); return }
                recordedModifiers = []
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                    if event.type == .flagsChanged {
                        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
                        // Save standalone Fn on press: the system's Globe action can
                        // consume its release or move focus before we receive it.
                        if event.keyCode == 63, flags == .function, recordedModifiers.isEmpty {
                            value = Shortcut.fromModifiers(flags)
                            stop()
                            return nil
                        }
                        if flags.isEmpty {
                            let shortcut = Shortcut.fromModifiers(recordedModifiers)
                            recordedModifiers = []
                            if let shortcut { value = shortcut; stop() }
                        } else { recordedModifiers.formUnion(flags) }
                    } else {
                        if event.keyCode == 53 { stop(); return nil }
                        if let shortcut = Shortcut.from(event) { value = shortcut; stop() }
                    }
                    return nil
                }
            }
            Button("Fn / 🌐") {
                stop()
                value = Shortcut.fromModifiers(.function)
            }
            .help("直接设置为单独 Fn 键，无需录制")
            if value != nil && monitor == nil { Button("清除") { value = nil } }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordedModifiers = []
    }
}
