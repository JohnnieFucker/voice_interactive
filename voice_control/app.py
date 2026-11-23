import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

from PySide6.QtCore import QLockFile, Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices, QGuiApplication
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QFileDialog, QHBoxLayout, QLabel,
    QMainWindow, QMessageBox, QPlainTextEdit, QPushButton, QTabWidget,
    QTextEdit, QVBoxLayout, QWidget,
)
from qasync import QEventLoop

from . import dsh
from .browser import ChromeScreens
from .companion import DesktopCompanion
from .config import data_dir, load, save, validate
from .network import ControllerServer, run_client
from .remote import Remote
from .settings import SettingsEditor
from .voice import InputMethod, audio_devices


class CommandEditor(QTextEdit):
    composing = False

    def inputMethodEvent(self, event):
        self.composing = bool(event.preeditString())
        super().inputMethodEvent(event)


class Window(QMainWindow):
    def __init__(self, role, config_path):
        super().__init__()
        self.role, self.config_path = role, config_path
        self.config = None
        self.tasks = set()
        self.service_tasks = set()
        self.server = self.browser = self.remote = self.input_method = None
        self.voice_start_task = None
        self.voice_finish_task = None
        self.voice_state = "idle"
        self.voice_buffer = bytearray()
        self.waiting_text = False
        self.voice_cancelled = False
        self.busy = False
        self.stopping = False
        self.stopped = asyncio.Event()
        self.stopped.set()
        self.start_task = None
        self.closing = False
        self.closed = asyncio.Event()
        self.setWindowTitle("语音集控端" if role == "controller" else "三屏客户端")
        self.resize(940, 740)
        self.tabs = QTabWidget()
        self.setCentralWidget(self.tabs)
        work = QWidget()
        layout = QVBoxLayout(work)
        title = QLabel("语音集控端" if role == "controller" else "三屏客户端")
        title.setStyleSheet("font-size: 24px; font-weight: 600; padding: 12px 0;")
        layout.addWidget(title)
        self.status = QLabel("尚未启动")
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        buttons = QHBoxLayout()
        self.start_button = QPushButton("启动服务" if role == "controller" else "打开三屏并连接")
        self.start_button.clicked.connect(lambda: self.spawn(self.start_services()))
        self.stop_button = QPushButton("停止")
        self.stop_button.clicked.connect(lambda: self.spawn(self.stop_services()))
        buttons.addWidget(self.start_button)
        buttons.addWidget(self.stop_button)
        layout.addLayout(buttons)
        if role == "controller":
            hint = QLabel("按住遥控器语音键说“进入总览模式”，也可以直接在下方输入。\n请先在配置页设置虚拟音频设备与输入法快捷键。")
            hint.setWordWrap(True)
            layout.addWidget(hint)
            self.editor = CommandEditor()
            self.editor.setAcceptRichText(False)
            self.editor.setPlaceholderText("语音输入法识别的文字显示在这里")
            self.editor.setAccessibleName("待处理的语音或文字指令")
            self.editor.textChanged.connect(self.text_changed)
            layout.addWidget(self.editor, 2)
            row = QHBoxLayout()
            self.submit = QPushButton("分析意图并执行")
            self.submit.clicked.connect(lambda: self.spawn(self.process_text()))
            row.addWidget(self.submit)
            self.auto_submit = QCheckBox("松键后自动提交稳定文字")
            row.addWidget(self.auto_submit)
            layout.addLayout(row)
            row = QHBoxLayout()
            self.mode_select = QComboBox()
            self.mode_select.setAccessibleName("手动选择模式")
            row.addWidget(self.mode_select)
            manual = QPushButton("手动切换模式")
            manual.clicked.connect(lambda: self.spawn(self.manual_mode()))
            row.addWidget(manual)
            layout.addLayout(row)
        else:
            info = QLabel("启动时打开配置中的三个页面。接收集控指令后，在原窗口切换 URL。\n请先检查屏幕顺序，并将集控端密钥填写到配置中。")
            info.setWordWrap(True)
            layout.addWidget(info)
        self.logs = QPlainTextEdit()
        self.logs.setReadOnly(True)
        self.logs.setMaximumBlockCount(250)
        self.logs.setAccessibleName("运行日志")
        layout.addWidget(self.logs, 2)
        self.tabs.addTab(work, "运行")
        self.build_config_tab()
        self.settle = QTimer(self)
        self.settle.setSingleShot(True)
        self.settle.timeout.connect(self.stable_text)
        self.text_deadline = QTimer(self)
        self.text_deadline.setSingleShot(True)
        self.text_deadline.timeout.connect(self.text_timeout)
        QApplication.instance().applicationStateChanged.connect(self.app_state_changed)
        self.tabs.currentChanged.connect(self.tab_changed)
        try:
            self.config = load(config_path, role)
            self.refresh_config()
            self.status.setText("配置已加载，请启动服务")
        except Exception as exc:
            # 损坏配置绝不自动覆盖。
            if config_path.exists():
                self.config_editor.setPlainText(config_path.read_text(encoding="utf-8", errors="replace"))
            self.log(f"读取配置失败，原文件保持不变：{exc}")
            self.tabs.setCurrentIndex(1)

        self.companion = None
        if self.role == "controller":
            self.companion = DesktopCompanion(self.companion_state)
            self.companion.settings_requested.connect(self.open_settings)
            self.companion.main_requested.connect(self.open_running)
            self.companion.exit_requested.connect(self.request_exit)

    def companion_state(self):
        if self.voice_state != "idle":
            return "listening"
        if self.busy:
            return "thinking"
        return "ready" if self.server else "idle"

    def open_settings(self):
        self.tabs.setCurrentIndex(1)
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def open_running(self):
        self.tabs.setCurrentIndex(0)
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def build_config_tab(self):
        panel = QWidget()
        layout = QVBoxLayout(panel)
        path = QLabel(f"配置文件：{self.config_path}")
        path.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        path.setWordWrap(True)
        layout.addWidget(path)
        hint = QLabel(
            "两端 token 必须相同，客户端 server_url 填集控电脑 IP。修改后点击保存，再启动。\n"
            "语音：virtual_output 填完整设备名；shortcut 如 <ctrl>+<alt>+v；trigger 为 hold / toggle。\n"
            "屏幕：默认按下方枚举顺序编号；可用 display_name 固定映射。示例 URL 请替换为实际页面。"
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)
        self.config_editor = SettingsEditor(self.role, self.displays)
        self.config_editor.setAccessibleName("应用设置")
        layout.addWidget(self.config_editor)
        row = QHBoxLayout()
        self.save_button = QPushButton("保存配置并停止当前服务")
        self.save_button.clicked.connect(lambda: self.spawn(self.save_config()))
        row.addWidget(self.save_button)
        devices = QPushButton("查看屏幕与音频设备")
        devices.clicked.connect(self.show_devices)
        row.addWidget(devices)
        if self.role == "controller":
            self.install_button = QPushButton("安装 dsh")
            self.install_button.clicked.connect(lambda: self.spawn(self.install_dsh()))
            row.addWidget(self.install_button)
            locate = QPushButton("选择已安装的 dsh")
            locate.clicked.connect(self.locate_dsh)
            row.addWidget(locate)
        layout.addLayout(row)
        if self.role == "controller":
            row = QHBoxLayout()
            help_button = QPushButton("打开 dsh 模型配置说明")
            help_button.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(
                "https://github.com/DeepSeek-ai/deepseek-harness/blob/master/docs/user/guide/providers.md")))
            row.addWidget(help_button)
            layout.addLayout(row)
        self.tabs.addTab(panel, "配置")

    def refresh_config(self):
        self.config_editor.setPlainText(json.dumps(self.config, ensure_ascii=False, indent=2))
        if self.role == "controller":
            self.auto_submit.setChecked(self.config["voice"].get("auto_submit", True))
            self.mode_select.clear()
            for mode in self.config["modes"]:
                self.mode_select.addItem(mode["name"], mode["id"])

    def log(self, message):
        self.logs.appendPlainText(time.strftime("%H:%M:%S") + "  " + str(message))
        self.status.setText(str(message)[:250])

    def spawn(self, coroutine, service=False):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        if service:
            self.service_tasks.add(task)
        def done(finished):
            self.tasks.discard(finished)
            self.service_tasks.discard(finished)
            if not finished.cancelled() and finished.exception():
                self.log(str(finished.exception()))
        task.add_done_callback(done)
        return task

    def displays(self):
        result = []
        for i, screen in enumerate(QGuiApplication.screens()):
            geometry = screen.geometry()
            result.append({"index": i + 1, "name": screen.name(), "x": geometry.x(), "y": geometry.y(),
                           "width": geometry.width(), "height": geometry.height()})
        return result

    def show_devices(self):
        try:
            text = json.dumps(self.displays(), ensure_ascii=False, indent=2) + "\n\n" + audio_devices()
            QMessageBox.information(self, "屏幕与音频设备", text)
        except Exception as exc:
            self.log(str(exc))

    async def save_config(self):
        config = validate(json.loads(self.config_editor.toPlainText()), self.role)
        await self.stop_services()
        save(self.config_path, config, self.role)
        self.config = config
        self.refresh_config()
        self.log("配置已保存，请重新启动服务")

    def locate_dsh(self):
        file, _ = QFileDialog.getOpenFileName(self, "选择 dsh 可执行文件")
        if file:
            try:
                config = json.loads(self.config_editor.toPlainText())
                config["dsh"]["executable"] = file
                self.config_editor.setPlainText(json.dumps(config, ensure_ascii=False, indent=2))
            except Exception as exc:
                self.log(f"请先修正配置：{exc}")

    async def install_dsh(self):
        self.install_button.setEnabled(False)
        self.log("正在准备 dsh 运行环境并安装到本应用数据目录，首次需要下载 Node 24…")
        try:
            executable = await dsh.install()
            config = json.loads(self.config_editor.toPlainText())
            config["dsh"]["executable"] = executable
            self.config_editor.setPlainText(json.dumps(config, ensure_ascii=False, indent=2))
            self.log("dsh 已安装。请保存配置，并按说明配置 dsh 模型密钥")
        finally:
            self.install_button.setEnabled(True)

    async def start_services(self):
        if not self.start_button.isEnabled() or self.stopping:
            return
        if not self.config:
            raise RuntimeError("请先修正并保存配置")
        self.start_button.setEnabled(False)
        self.start_task = asyncio.current_task()
        try:
            if self.role == "controller":
                self.server = ControllerServer(self.config, self.log)
                await self.server.start()
                self.input_method = InputMethod(self.config["voice"])
                self.remote = Remote(self.config["voice"], self.voice_start, self.voice_audio, self.voice_stop, self.log)
                self.spawn(self.remote.run(), service=True)
            else:
                self.browser = ChromeScreens(self.config, self.displays)
                results = await self.browser.apply(self.config["screens"])
                self.log("启动页面：" + json.dumps(results, ensure_ascii=False))
                self.spawn(run_client(self.config, self.browser, self.displays, self.log), service=True)
        except BaseException:
            if not self.stopping:
                await self.stop_services()
            raise
        finally:
            self.start_task = None

    async def stop_services(self):
        if self.stopping:
            await self.stopped.wait()
            return
        self.stopping = True
        self.stopped.clear()
        self.clear_text_wait()
        async def cleanup(operation):
            try:
                await operation
            except Exception as exc:
                self.log(f"停止时发生错误：{exc}")
        try:
            if self.start_task and self.start_task is not asyncio.current_task() and not self.start_task.done():
                self.start_task.cancel()
                await asyncio.gather(self.start_task, return_exceptions=True)
            if self.remote:
                await cleanup(self.remote.close())
            tasks = list(self.service_tasks)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for task in (self.voice_start_task, self.voice_finish_task):
                if task and not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
            if self.input_method:
                try:
                    self.input_method.abort(can_toggle=self.editor.hasFocus() and self.isActiveWindow())
                except Exception as exc:
                    self.log(str(exc))
            if self.server:
                await cleanup(self.server.close())
            if self.browser:
                await cleanup(self.browser.close())
        finally:
            self.remote = self.input_method = self.server = self.browser = None
            self.voice_buffer.clear()
            self.voice_state = "idle"
            self.start_button.setEnabled(True)
            self.stopping = False
            self.stopped.set()
            self.log("服务已停止")

    def voice_start(self):
        if self.busy or self.voice_state != "idle" or self.waiting_text or self.stopping or self.closing:
            self.log("请等待上一条指令处理完成")
            return False
        self.clear_text_wait()
        self.voice_cancelled = False
        self.voice_state = "starting"
        self.voice_buffer.clear()
        self.voice_start_task = self.spawn(self.begin_voice())
        return True

    async def begin_voice(self):
        try:
            self.tabs.setCurrentIndex(0)
            self.showNormal()
            self.raise_()
            self.activateWindow()
            self.editor.setFocus()
            for _ in range(15):
                if self.editor.hasFocus() and self.isActiveWindow():
                    break
                await asyncio.sleep(0.1)
            if not self.editor.hasFocus() or not self.isActiveWindow():
                raise RuntimeError("集控输入框未获得焦点，已取消语音，请点击集控窗口后重试")
            self.editor.clear()
            self.input_method.start()
            self.voice_state = "recording"
            if self.voice_buffer:
                self.input_method.write(bytes(self.voice_buffer))
                self.voice_buffer.clear()
            self.log("语音输入中，请说话")
        except BaseException:
            self.voice_cancelled = True
            self.voice_state = "idle"
            if self.remote:
                self.remote.failed.set()
            raise

    def voice_audio(self, pcm):
        if self.voice_state == "starting":
            if len(self.voice_buffer) + len(pcm) > 96000:
                raise RuntimeError("输入法启动过慢，已取消语音")
            self.voice_buffer.extend(pcm)
        elif self.voice_state == "recording":
            self.input_method.write(pcm)

    def voice_stop(self, cancelled):
        self.voice_cancelled |= cancelled
        if not self.voice_finish_task or self.voice_finish_task.done():
            self.voice_finish_task = self.spawn(self.finish_voice())

    async def finish_voice(self):
        try:
            if self.voice_start_task:
                await self.voice_start_task
            if self.voice_state != "recording":
                return
            self.voice_state = "stopping"
            await self.input_method.finish(
                cancelled=self.voice_cancelled,
                can_toggle=lambda: self.editor.hasFocus() and self.isActiveWindow(),
            )
            if self.voice_cancelled or not self.editor.hasFocus() or not self.isActiveWindow():
                self.log("本次语音已取消，文字未提交")
                return
            self.waiting_text = True
            self.text_deadline.start(20000)
            self.settle.start(self.config["voice"]["settle_ms"])
            self.log("语音已结束，等待输入法文字稳定")
        finally:
            self.voice_state = "idle"
            self.voice_buffer.clear()

    def text_changed(self):
        if self.waiting_text:
            self.settle.start(self.config["voice"]["settle_ms"])

    def stable_text(self):
        if not self.waiting_text or self.voice_state != "idle":
            return
        if not self.editor.hasFocus() or not self.isActiveWindow():
            self.clear_text_wait()
            self.log("焦点已变化，已停止自动提交")
            return
        if not self.editor.toPlainText().strip() or self.editor.composing:
            # 空白或仍在输入法候选阶段，继续等待；最终由截止计时器取消。
            self.settle.start(self.config["voice"]["settle_ms"])
            return
        self.clear_text_wait()
        if self.auto_submit.isChecked():
            self.spawn(self.process_text())
        else:
            self.log("文字已就绪，请点击“分析意图并执行”")

    def text_timeout(self):
        self.clear_text_wait()
        self.log("等待识别文字超时，请检查输入法；已有文字可手动提交")

    def clear_text_wait(self):
        self.waiting_text = False
        self.settle.stop()
        self.text_deadline.stop()

    def app_state_changed(self, state):
        if self.role != "controller":
            return
        if state != Qt.ApplicationState.ApplicationActive:
            self.clear_text_wait()
            if self.voice_state in ("starting", "recording", "stopping"):
                self.voice_cancelled = True
                if self.remote:
                    self.remote.failed.set()

    def tab_changed(self, index):
        if self.role == "controller" and index != 0:
            self.clear_text_wait()
            if self.voice_state in ("starting", "recording", "stopping"):
                self.voice_cancelled = True
                if self.remote:
                    self.remote.failed.set()

    async def process_text(self):
        if self.busy or self.voice_state != "idle" or self.stopping:
            raise RuntimeError("请等待语音结束或上一条指令执行完成")
        if not self.server:
            raise RuntimeError("请先启动集控服务")
        self.clear_text_wait()
        text = self.editor.toPlainText().strip()
        self.busy = True
        self.submit.setEnabled(False)
        server = self.server
        try:
            self.log("正在由 dsh 分析意图…")
            mode = await dsh.choose_mode(text, self.config)
            if self.server is not server or self.closing:
                raise RuntimeError("集控服务已停止，本次分析结果已丢弃")
            self.log(f"dsh 选择：{mode['name']}")
            await server.dispatch(mode)
        finally:
            self.busy = False
            self.submit.setEnabled(True)

    async def manual_mode(self):
        if self.busy or self.voice_state != "idle" or self.stopping or not self.server:
            raise RuntimeError("请启动服务并等待当前操作结束")
        self.clear_text_wait()
        mode = next(m for m in self.config["modes"] if m["id"] == self.mode_select.currentData())
        self.busy = True
        try:
            await self.server.dispatch(mode)
        finally:
            self.busy = False

    def closeEvent(self, event):
        event.ignore()
        if self.role == "controller" and not self.closing:
            self.clear_text_wait()
            if self.voice_state != "idle":
                self.voice_cancelled = True
                if self.remote and self.remote.failed:
                    self.remote.failed.set()
            self.hide()
            return
        self.request_exit()

    def request_exit(self):
        if not self.closing:
            self.closing = True
            self.spawn(self.shutdown())

    async def shutdown(self):
        try:
            await self.stop_services()
            current = asyncio.current_task()
            pending = [task for task in self.tasks if task is not current]
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        finally:
            if self.companion:
                self.companion.shutdown()
            self.hide()
            self.closed.set()


def main(role):
    parser = argparse.ArgumentParser(description="语音三屏集控")
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    app = QApplication(sys.argv[:1])
    app.setApplicationName("VoiceScreenControl")
    app.setQuitOnLastWindowClosed(False)
    directory = data_dir()
    directory.mkdir(parents=True, exist_ok=True)
    lock = QLockFile(str(directory / f"{role}.lock"))
    lock.setStaleLockTime(0)
    if not lock.tryLock(100):
        QMessageBox.warning(None, "程序已运行", "同一角色只允许运行一个实例，请检查已打开的窗口。")
        return
    loop = QEventLoop(app)
    asyncio.set_event_loop(loop)
    with loop:
        window = Window(role, (args.config or directory / f"{role}.json").resolve())
        if window.companion:
            window.companion.show()
        else:
            window.show()
        loop.run_until_complete(window.closed.wait())
    lock.unlock()


def controller_main():
    main("controller")


def client_main():
    main("client")
