# 语音三屏集控

两个独立的桌面程序，面向 macOS 13+ 和 Windows 10 / 11 x64：

- **集控端 VoiceController**：连接小米蓝牙语音遥控器，通过已有语音输入法获取文字，调用本机 DeepSeek Harness 分析模式，再通过 WebSocket 下发指令。
- **客户端 ScreenClient**：控制已安装的 Google Chrome，用三个独立窗口在三块屏幕显示指定 URL，切换后回报逐屏结果。

完整保留原始 `remote_mic` 源码于 `vendor/remote_mic`。新程序将其 ATVV 音频协议、解码、握手、同步和重连流程移植为 Python，使用同一套代码接入两种系统。原始 Swift 应用依然保留，不修改原仓库。

**当前是首版源码，尚未在两种系统完成遥控器、输入法、三屏联调，也没有构建安装包。**

## 工作流程

```text
遥控器语音键与音频
  → 集控端蓝牙接入、16 kHz ADPCM 解码
  → BlackHole / VB-CABLE 虚拟音频设备
  → 已安装的语音输入法（快捷键启动与结束）
  → 集控端文字框
  → 本机 dsh headless 分析，返回模式 ID
  → WebSocket set_mode
  → 客户端 Chrome 三屏切换
  → 逐屏执行结果回传
```

没有独立 ASR 服务。输入法保持原有产品及账号配置，集控端不提取第三方输入法的内部数据。

默认模式：

| 模式 | 1 号屏幕 | 2 号屏幕 | 3 号屏幕 |
| --- | --- | --- | --- |
| 总览模式 | 总览 | 进度 | 消息 |
| 生产模式 | 生产 | 设备 | 质量 |
| 演示模式 | 介绍 | 演示 | 总结 |

以上都是 `https://example.com/?page=...` 占位页面，请在集控端配置的 `modes[].screens` 中替换。

## 源码启动

需要 Python 3.11+、Google Chrome。集控电脑另外需要语音输入法、虚拟音频驱动，以及能运行的 dsh。

macOS：

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
python -m voice_control controller
```

Windows PowerShell：

```powershell
py -3.11 -m venv .venv
.venv\Scripts\python.exe -m pip install -e .
.venv\Scripts\python.exe -m voice_control controller
```

运行客户端，将最后一个参数改为 `client`。也可使用安装后提供的 `voice-controller` / `voice-client` 命令。
无需执行 `playwright install`，程序选择本机已安装的 Google Chrome。

首次运行自动生成配置，原配置损坏时不会覆盖：

- macOS：`~/Library/Application Support/VoiceScreenControl/controller.json` 和 `client.json`。
- Windows：`%LOCALAPPDATA%\VoiceScreenControl\controller.json` 和 `client.json`。
- 自定义位置：`python -m voice_control controller --config /绝对路径/controller.json`。

## 首次设置

1. **连接配置**：将集控端配置中的 `token` 复制到客户端配置。两端首次生成的密钥不同，必须手动统一。客户端 `server_url` 设置为 `ws://集控电脑局域网IP:8765`，不包含 `/control`。允许集控程序通过防火墙访问专用局域网。
2. **客户端身份**：客户端默认 ID 为 `display-01`，须与集控端 `target_clients` 一致。多台客户端须使用不同 ID，并将它们加入目标列表。
3. **三屏配置**：客户端点击“查看屏幕与音频设备”，确认屏幕枚举顺序。默认对应第 1、2、3 块屏幕；如需固定映射，在 `screens[].display_name` 填完整屏幕名称。名称重复时使用枚举顺序。三个编号必须对应三块不同的显示器。
4. **初始页面**：客户端 `screens[].url` 定义启动时的三个页面；集控端 `modes[].screens[].url` 定义切换后的三个页面。两者作用不同。
5. **遥控器配对**：先在系统蓝牙设置中配对，退出 RemoteVibe、SayAll 等占用同一遥控器的程序。集控端启动后自动搜索已知小米设备；也可填写 `voice.remote_address`（Mac 的设备 UUID，Windows 的蓝牙地址）。
6. **虚拟音频**：按下一节配置设备和语音快捷键。
7. **dsh**：按后文安装或选择已有 dsh，并配置模型。
8. **启动顺序**：先启动集控服务，再启动客户端。先用“手动切换模式”验证三屏，再在文字框输入“进入总览模式”验证 dsh，最后用遥控器说话。

## 沿用语音输入法

### macOS

安装 BlackHole 2ch，或沿用已有 MiRemoteV 2ch。集控端点击“查看屏幕与音频设备”，在 `voice.virtual_output` 填写设备完整名称，例如 `BlackHole 2ch`。在语音输入法中选择同一个虚拟设备作为输入。

授权集控端使用蓝牙和辅助功能。源码运行时系统可能将权限归到终端或 Python；打包应用已声明蓝牙用途。

### Windows

安装 VB-CABLE。在集控端 `voice.virtual_output` 填写设备列表中的 **CABLE Input** 完整名称，在语音输入法中选择对应的 **CABLE Output** 录音设备。驱动装好后可能需要重启。程序不安装驱动、不修改系统默认输入或输出。

### 快捷键与文字提交

`voice.shortcut` 必须与输入法自己的设置相同，默认 `<ctrl>+<alt>+v` 只是示例。支持如 `<cmd>+<shift>+v`、`<alt>+<space>` 等 pynput 快捷键表达式；本版没有移植原生 Fn 或双击 Fn 特殊触发，建议在输入法里改为普通组合键。

- `voice.trigger: "hold"`：按住遥控器语音时按住快捷键，松开后释放。
- `voice.trigger: "toggle"`：语音开始与结束时各点按一次快捷键。
- 遥控器音频先写入虚拟输出，松键后等已排队音频输出完再结束快捷键。
- 自动提交：松键后等待文字连续 `voice.settle_ms` 毫秒不变（默认 1800），且无 Qt 输入法预编辑内容，再送到 dsh；20 秒未就绪则取消自动提交。
- 输入法没有统一的识别完成通知，因此文字稳定是时间判断，不能保证所有输入法都已完成最终识别。可增加等待时间，或取消运行页中的自动提交选项，改为手动提交。
- 切换应用、切到配置页或断开遥控器会取消自动提交。点按模式已切换焦点时不会向其他应用发送停止快捷键，日志会提示手动结束输入法。

仅允许写入明确选择的 BlackHole、MiRemoteV 或 VB-CABLE，设备缺失不回退到扬声器。音频积压超过 3 秒、单次语音超过 60 秒会取消当前语音。

## DeepSeek Harness

集控端“安装 dsh”会调用已安装 Node.js LTS 自带的 npm，将官方 `@deepseek-ai/dsh` 安装到本应用数据目录的 `runtime`，不覆盖系统 dsh。
已有安装可点击“选择已安装的 dsh”，或填写 `dsh.executable` 的完整路径，然后保存。

这里的 dsh 地址是**本机可执行文件路径**。当前通过官方 `headless` 命令调用，不把 dsh 的 Web UI 地址当作模型 API；本版未实现远程 HTTP dsh 接入。

本次检查发现开发机 `/usr/local/bin/dsh` 指向 iDesk Koi 内已不存在的 `DeepSeek Harness` 可执行文件；该路径需要修复，或通过程序重新安装独立 dsh。

官方 headless 使用启动环境或 `.env` 的模型配置，**不会直接读取 GUI 保存的模型密钥**。可在 `~/.dsh/.env` 中设置：

```dotenv
DEEPSEEK_API_KEY=你的模型密钥
```

如果设置了 `DSH_HOME`，则使用 `$DSH_HOME/.env`。兼容模型端点及提供商配置遵循所安装的 dsh 版本，不在集控端保存模型密钥。
调用时使用独立工作目录、`read-only` 权限、`never` 审批策略和默认 90 秒超时。只接受正常完成且返回有效 JSON 的结果，并把模式 ID 映射回本机配置；未知模式或含糊结果不下发。模型不能自行提供任意 URL 或可执行命令。

参考：[官方安装说明](https://github.com/DeepSeek-ai/deepseek-harness)、[headless 接口和密钥说明](https://github.com/DeepSeek-ai/deepseek-harness/blob/master/packages/bundle/headless/README.md)。dsh 为快速变化的开发预览版，升级后应重新确认 CLI 与 JSON 格式。

## 通信与执行规则

- 集控端监听 `/control` WebSocket，握手校验 Bearer 密钥，拒绝来自网页 Origin 的连接。
- 只接受 `set_mode` 指令，每条包含 UUID、30 秒有效期、三个已配置 URL。
- 客户端去重最近 256 条指令，连接恢复后保留缓存；过期指令拒绝执行，不自动补发离线期间的指令。
- 回执超时或掉线只报告结果未知，不把已发送当作执行成功。
- 屏幕、URL 在执行前验证；页面逐屏加载，回执报告每块屏幕结果。三屏切换不是原子事务，失败时可能已经切换其中部分页面。
- 显示器热插拔会在下次切换时重新枚举，不自动移动已有页面。若配置屏幕不存在则明确报错。
- Chrome 使用应用数据目录下三个独立的浏览器配置，不占用用户日常浏览器配置。退出或停止客户端会关闭它管理的三个窗口。
- 默认是可信局域网内的 `ws://` 连接。跨不可信网络应由反向代理提供 TLS，再使用 `wss://` 地址。

## 打包

以下为待执行的打包步骤，本次没有运行。两种系统需分别在目标系统上构建，macOS 的 Intel / Apple Silicon 也分别构建。

```sh
python -m pip install -e '.[package]'
pyinstaller --noconfirm packaging/apps.spec
```

- macOS：生成 `dist/VoiceController.app` 和 `dist/ScreenClient.app`，执行 `sh packaging/macos-dmg.sh` 生成拖拽安装的 DMG。正式分发前需配置 `CODE_SIGN_IDENTITY` 并完成 Apple 公证；同一签名身份有利于保持系统权限。
- Windows：生成两个程序目录，用 Inno Setup 6 编译 `packaging/windows.iss`，生成可选择安装集控端、客户端或两者的安装程序。
- Chrome、语音输入法、虚拟音频驱动、Node.js 不随安装包分发。dsh 可在集控端按需安装。

## 检查与实机验收

无需编译应用的逻辑检查：

```sh
python -B -m unittest discover -s tests -v
```

覆盖原始 ADPCM 已知向量、字节顺序与同步状态、能力包校验、损坏配置保护、屏幕和 URL 校验、过期指令、dsh 输出白名单、进程超时和真实本机 WebSocket 握手与执行回执。

实机仍需分别在 macOS / Windows 验收：蓝牙授权与配对、连续按住松开、睡眠唤醒、断线时释放快捷键、输入法文字完整性、三屏枚举、混合 DPI、全屏定位和屏幕热插拔。当前不声称这些检查已经通过。

本版只实现语音模式切换，不移植原项目的 iTerm2 按键控制、分屏测试向导；它们与三屏 URL 切换无关。原代码完整保留可供后续复用。

## 许可

GPL-3.0-only。来源与第三方说明见 `THIRD_PARTY_NOTICES.md` 及 `vendor/remote_mic/THIRD_PARTY_NOTICES.md`。
