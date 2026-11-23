# 来源与许可

本项目复用、移植 `~/code/remote_mic`（RemoteVibe）的代码，按 GPL-3.0-only 分发，见 LICENSE。
RemoteVibe Copyright (c) 2026 ShineLee；其完整原始代码保存在 `vendor/remote_mic`，排除构建产物、Git 历史及本机签名信息。
复制时原仓库 HEAD 为 `21263cd2c45ac79399dbf958d495089f1c30604c`，保留当时工作区文件内容。

`voice_control/atvv.py` 是 `Sources/RemoteVibe/ATVVProtocol.swift` 的 Python 移植。
`voice_control/remote.py` 参考 `BluetoothBridge.swift` 的能力协商、通知订阅、音频分帧、同步包、会话延长和重连流程，使用 Bleak 实现 macOS / Windows 接入。

上游来源：SayAll（HD838A/remote-mic-app），Copyright (C) 2026 SayAll contributors，GPL-3.0-only。
更多来源、参考提交及资源许可见 `vendor/remote_mic/THIRD_PARTY_NOTICES.md`。
原项目 MIT 声明保存在 `vendor/remote_mic/LICENSE-MIT`。
本程序的界面不使用上游遥控器照片或专有应用图标。

PySide6、qasync、Bleak、websockets、Playwright、sounddevice、pynput、PyInstaller 及其依赖遵循各自许可。
发行二进制时须同时提供本项目对应源码、许可及所包含依赖的许可，尤其是 Qt / PySide6 的适用义务。
Chrome、语音输入法、虚拟音频驱动、Node.js 和 DeepSeek Harness 由用户另行安装，不包含在本项目中。

桌面龙宝形象使用用户指定的原始精灵图：
https://jlagent.ejianlong.com/office-home/hero-mascot-sprite.webp
资源保存在 `voice_control/assets/hero-mascot-sprite.webp`，保持原文件内容，程序运行时切帧播放。图像权利归原权利人所有。
