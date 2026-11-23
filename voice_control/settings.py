import copy
import json
import uuid

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QFormLayout, QHBoxLayout, QLabel, QLineEdit,
    QPlainTextEdit, QPushButton, QScrollArea, QSpinBox, QTabWidget,
    QVBoxLayout, QWidget,
)


class SettingsEditor(QWidget):
    """常用设置使用原生表单；高级 JSON 保留未展示的配置字段。"""
    def __init__(self, role, displays):
        super().__init__()
        self.role, self.displays = role, displays
        self.config = None
        self.fields = {}
        self.mode_index = -1
        self.modes = []
        self.previous_tab = 0
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self.error = QLabel()
        self.error.setWordWrap(True)
        layout.addWidget(self.error)
        self.tabs = QTabWidget()
        layout.addWidget(self.tabs)
        self.general = self.form_page("连接")
        self.line(self.general, "连接密钥", ("token",), secret=True)
        if role == "controller":
            self.line(self.general, "监听地址", ("host",))
            self.spin(self.general, "监听端口", ("port",), 1, 65535)
            self.targets = QLineEdit()
            self.targets.setPlaceholderText("display-01, display-02")
            self.general.addRow("目标客户端（逗号分隔）", self.targets)
            self.build_voice()
            self.build_modes()
        else:
            self.line(self.general, "客户端名称", ("client_id",))
            self.line(self.general, "集控地址", ("server_url",))
            self.line(self.general, "Chrome 路径（留空自动查找）", ("chrome_path",))
            self.check(self.general, "全屏显示", ("fullscreen",))
            self.build_screens()
        self.raw = QPlainTextEdit()
        self.raw.setAccessibleName("高级 JSON 配置")
        self.tabs.addTab(self.raw, "高级配置")
        self.tabs.currentChanged.connect(self.change_tab)

    def form_page(self, name):
        panel = QWidget()
        form = QFormLayout(panel)
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        form.setSpacing(12)
        form.setContentsMargins(20, 20, 20, 20)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(panel)
        self.tabs.addTab(scroll, name)
        return form

    def line(self, form, label, path, secret=False):
        edit = QLineEdit()
        edit.setAccessibleName(label)
        if secret:
            edit.setEchoMode(QLineEdit.EchoMode.Password)
            row = QWidget()
            layout = QHBoxLayout(row)
            layout.setContentsMargins(0, 0, 0, 0)
            layout.addWidget(edit)
            reveal = QCheckBox("显示")
            reveal.toggled.connect(lambda checked: edit.setEchoMode(
                QLineEdit.EchoMode.Normal if checked else QLineEdit.EchoMode.Password))
            layout.addWidget(reveal)
            form.addRow(label, row)
        else:
            form.addRow(label, edit)
        self.fields[path] = (edit.setText, edit.text)
        return edit

    def spin(self, form, label, path, minimum, maximum):
        edit = QSpinBox()
        edit.setRange(minimum, maximum)
        edit.setAccessibleName(label)
        form.addRow(label, edit)
        self.fields[path] = (edit.setValue, edit.value)
        return edit

    def check(self, form, label, path):
        edit = QCheckBox(label)
        form.addRow(edit)
        self.fields[path] = (edit.setChecked, edit.isChecked)

    def build_voice(self):
        form = self.form_page("遥控器与语音")
        self.line(form, "遥控器地址（留空自动搜索）", ("voice", "remote_address"))
        device_row = QWidget()
        row = QHBoxLayout(device_row)
        row.setContentsMargins(0, 0, 0, 0)
        self.audio = QComboBox()
        self.audio.setEditable(True)
        self.audio.setAccessibleName("虚拟音频输出设备")
        row.addWidget(self.audio, 1)
        refresh = QPushButton("刷新设备")
        refresh.clicked.connect(self.refresh_audio)
        row.addWidget(refresh)
        form.addRow("虚拟音频输出", device_row)
        self.fields[("voice", "virtual_output")] = (self.audio.setCurrentText, self.audio.currentText)
        self.line(form, "输入法快捷键", ("voice", "shortcut"))
        help_text = QLabel("与输入法内的设置保持一致，例如 <ctrl>+<alt>+v。\nMac 选择 BlackHole，Windows 选择 CABLE Input；输入法需选择对应的录音设备。")
        help_text.setWordWrap(True)
        form.addRow(help_text)
        trigger = QComboBox()
        trigger.addItem("按住快捷键说话", "hold")
        trigger.addItem("开始与结束各点按一次", "toggle")
        form.addRow("快捷键触发方式", trigger)
        self.fields[("voice", "trigger")] = (
            lambda value: trigger.setCurrentIndex(max(0, trigger.findData(value))), trigger.currentData)
        self.spin(form, "文字稳定等待（毫秒）", ("voice", "settle_ms"), 500, 15000)
        self.check(form, "语音结束后自动提交文字", ("voice", "auto_submit"))
        self.check(form, "ARN9 音频字节顺序（其他型号不勾选）", ("voice", "low_nibble_first"))
        form = self.form_page("DeepSeek Harness")
        self.line(form, "dsh 可执行文件路径", ("dsh", "executable"))
        self.spin(form, "分析超时（秒）", ("dsh", "timeout_seconds"), 5, 600)
        text = QLabel("使用本机 dsh 命令。可通过下方按钮安装，或选择已安装的程序。\n模型密钥沿用 dsh 的环境变量或 ~/.dsh/.env 配置。")
        text.setWordWrap(True)
        form.addRow(text)

    def refresh_audio(self):
        try:
            import sounddevice as sd
            current = self.audio.currentText()
            names = sorted({d["name"] for d in sd.query_devices()
                            if d["max_output_channels"] >= 2
                            and any(s in d["name"].lower() for s in ("blackhole", "miremotev", "cable input"))})
            self.audio.clear()
            self.audio.addItems(names)
            self.audio.setCurrentText(current)
            self.error.setText("" if names else "未找到虚拟音频设备，请安装 BlackHole 或 VB-CABLE 后刷新。")
        except Exception as exc:
            self.error.setText(f"无法枚举音频设备：{exc}")

    def build_screens(self):
        form = self.form_page("三个屏幕")
        hint = QLabel("默认按当前系统枚举顺序编号，也可以为每个编号选择固定屏幕名称。")
        hint.setWordWrap(True)
        form.addRow(hint)
        self.screen_fields = []
        for number in (1, 2, 3):
            display = QComboBox()
            display.setEditable(True)
            display.addItem("")
            display.addItems([s["name"] for s in self.displays()])
            display.setAccessibleName(f"{number} 号屏幕设备")
            url = QLineEdit()
            url.setAccessibleName(f"{number} 号屏幕初始 URL")
            form.addRow(f"{number} 号屏幕（留空按顺序）", display)
            form.addRow(f"{number} 号屏幕初始页面", url)
            self.screen_fields.append((display, url))

    def build_modes(self):
        form = self.form_page("显示模式")
        row = QWidget()
        buttons = QHBoxLayout(row)
        buttons.setContentsMargins(0, 0, 0, 0)
        self.mode_select = QComboBox()
        self.mode_select.setAccessibleName("编辑显示模式")
        self.mode_select.currentIndexChanged.connect(self.select_mode)
        buttons.addWidget(self.mode_select, 1)
        add = QPushButton("新增")
        add.clicked.connect(self.add_mode)
        buttons.addWidget(add)
        remove = QPushButton("删除")
        remove.clicked.connect(self.remove_mode)
        buttons.addWidget(remove)
        form.addRow("选择模式", row)
        self.mode_name = QLineEdit()
        self.mode_description = QLineEdit()
        form.addRow("模式名称", self.mode_name)
        form.addRow("意图描述", self.mode_description)
        self.mode_urls = [QLineEdit() for _ in range(3)]
        for number, edit in enumerate(self.mode_urls, 1):
            edit.setAccessibleName(f"模式的 {number} 号屏幕 URL")
            form.addRow(f"{number} 号屏幕 URL", edit)

    def store_mode(self):
        if 0 <= self.mode_index < len(self.modes):
            mode = self.modes[self.mode_index]
            mode.update(name=self.mode_name.text(), description=self.mode_description.text())
            mode["screens"] = [{"number": i + 1, "url": field.text()} for i, field in enumerate(self.mode_urls)]
            self.mode_select.setItemText(self.mode_index, mode["name"])

    def select_mode(self, index):
        self.store_mode()
        self.mode_index = index
        if 0 <= index < len(self.modes):
            mode = self.modes[index]
            self.mode_name.setText(mode["name"])
            self.mode_description.setText(mode.get("description", ""))
            for item in mode["screens"]:
                self.mode_urls[item["number"] - 1].setText(item["url"])

    def add_mode(self):
        self.store_mode()
        self.modes.append({"id": uuid.uuid4().hex, "name": "新模式", "description": "",
                           "screens": [{"number": n, "url": "https://example.com"} for n in (1, 2, 3)]})
        self.mode_select.addItem("新模式")
        self.mode_select.setCurrentIndex(len(self.modes) - 1)

    def remove_mode(self):
        if len(self.modes) <= 1:
            self.error.setText("至少保留一个模式。")
            return
        del self.modes[self.mode_index]
        self.mode_index = -1
        self.populate_modes()

    def populate_modes(self):
        self.mode_select.blockSignals(True)
        self.mode_select.clear()
        self.mode_select.addItems([m["name"] for m in self.modes])
        self.mode_select.blockSignals(False)
        self.mode_index = -1
        self.select_mode(0)

    def populate(self, config):
        self.config = copy.deepcopy(config)
        for path, (setter, _) in self.fields.items():
            value = config
            for part in path:
                value = value[part]
            setter(value)
        if self.role == "controller":
            self.targets.setText(", ".join(config["target_clients"]))
            self.modes = copy.deepcopy(config["modes"])
            self.populate_modes()
        else:
            for item in config["screens"]:
                display, url = self.screen_fields[item["number"] - 1]
                display.setCurrentText(item.get("display_name", ""))
                url.setText(item["url"])

    def collect(self):
        config = copy.deepcopy(self.config)
        for path, (_, getter) in self.fields.items():
            target = config
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = getter()
        if self.role == "controller":
            self.store_mode()
            config["target_clients"] = [x.strip() for x in self.targets.text().replace("，", ",").split(",") if x.strip()]
            config["modes"] = copy.deepcopy(self.modes)
        else:
            for item in config["screens"]:
                display, url = self.screen_fields[item["number"] - 1]
                item.update(display_name=display.currentText(), url=url.text())
        return config

    def setPlainText(self, text):
        self.raw.setPlainText(text)
        try:
            config = json.loads(text)
            from .config import validate
            validate(config, self.role)
            self.populate(config)
            self.error.clear()
        except Exception as exc:
            self.config = None
            self.error.setText(f"请在高级配置中修正：{exc}")
            self.tabs.setCurrentWidget(self.raw)

    def toPlainText(self):
        if self.tabs.currentWidget() is self.raw or self.config is None:
            return self.raw.toPlainText()
        return json.dumps(self.collect(), ensure_ascii=False, indent=2)

    def change_tab(self, index):
        try:
            if self.previous_tab == self.tabs.indexOf(self.raw):
                config = json.loads(self.raw.toPlainText())
                from .config import validate
                self.populate(validate(config, self.role))
            elif self.config is not None:
                self.raw.setPlainText(json.dumps(self.collect(), ensure_ascii=False, indent=2))
            self.error.clear()
            self.previous_tab = index
        except Exception as exc:
            self.error.setText(f"请先修正高级配置：{exc}")
            self.tabs.blockSignals(True)
            self.tabs.setCurrentWidget(self.raw)
            self.tabs.blockSignals(False)
            self.previous_tab = self.tabs.indexOf(self.raw)
