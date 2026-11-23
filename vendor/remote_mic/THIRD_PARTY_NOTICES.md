# 来源与许可

RemoteVibe Copyright (c) 2026 ShineLee。

本次重构包含对 [HD838A/remote-mic-app（SayAll）](https://github.com/HD838A/remote-mic-app) 开源代码的复用与修改，项目软件代码按 **GPL-3.0-only** 分发，许可全文见 `LICENSE`。重构前原创代码的 MIT 声明保留在 `LICENSE-MIT`。

上游：SayAll，Copyright (C) 2026 SayAll contributors。2026-10-20 读取公开 main 分支，参考提交 `4b170d2925f0b806d2a0b3f87ef8494db93bd7fa`：

- `ATVVProtocol.swift`：ATVV 命令、能力解析、IMA ADPCM 解码、音频分帧与增益处理；删除语音使用统计辅助方法。
- `RemoteButtons.swift`：`RemoteHIDReportParser` 和小米按键 usage 映射；抽取为 `RemoteReportParser`，保留输入格式校验。
- `KeyboardEventSuppressor.swift`、`HIDRemoteMonitor.swift`：参考独占失败后共享读取及原生按键时序过滤；精简为共享模式过滤器，保留合成事件豁免和停止时清理。
- `AudioExceptionGuard.h`、`AudioExceptionGuard.m`：保留音频播放的 Objective-C 异常保护。
- `XiaomiBluetoothBridge.swift`、`HIDRemoteMonitor.swift`、`AudioOutput.swift`：参考小米蓝牙握手、同步包、连接生命周期、严格 HID 匹配、独占策略和指定音频输出的实现，重写为精简模块。
- `Resources/RC003-remote-photo.png`、`RemoteMappingCanvas.swift`：复用小米遥控器图片及其归一化按键热点坐标，图片保持原始内容；用于连接、按键配置和首次配置向导。上游注明该照片由用户于 2026-07-17 提供，图像及所示产品的版权和商标权归相应权利人所有，程序的 GPL 许可不额外授予该照片或小米商标的权利。
- `OnboardingView.swift`、`OnboardingFlow.swift`：复用阶段导航、双栏配置、右侧背景及图像布局，重写为小米遥控器与 iTerm2 的精简分步配置；去掉会员、手机连接和其他遥控器分支。
- `SettingsView.swift`、`design-qa.md`：参考三页布局、遥控器按键热点、原生系统外观和最小中文字号规范，未拷贝完整设置页及扩展模块。

上游声明其 macOS 适配参考了 GPL-3.0-only 项目 [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub)，参考提交 `8a93f321ac71a602300c6cd77f7256fa4b63068e`。相关权利归原作者所有。

本项目未使用或分发 SayAll 的专有 App Logo、产品商标图标或私人功能包。小米遥控器实物图片复用上游公开资源，SwiftUI 仅绘制选中和按下状态。macOS 系统框架与 SF Symbols 的使用遵循 Apple 相应条款。

虚拟音频驱动不包含在本项目中，用户另外安装的 BlackHole 或 MiRemoteV 驱动遵循其各自许可。
