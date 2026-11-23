import copy
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit


def data_dir():
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local"))
    else:
        base = Path.home() / "Library/Application Support"
    return base / "VoiceScreenControl"


def default_config(role):
    shared = {"token": secrets.token_urlsafe(32)}
    if role == "client":
        return shared | {
            "client_id": "display-01", "server_url": "ws://127.0.0.1:8765",
            "chrome_path": "", "fullscreen": True,
            "screens": [
                {"number": n, "display_name": "", "url": "https://example.com"}
                for n in (1, 2, 3)
            ],
        }
    return shared | {
        "host": "0.0.0.0", "port": 8765,
        "target_clients": ["display-01"],
        "dsh": {"executable": "dsh", "timeout_seconds": 90},
        "voice": {
            "remote_address": "", "virtual_output": "",
            "shortcut": "<ctrl>+<alt>+v", "trigger": "hold",
            "auto_submit": True, "settle_ms": 1800,
            "low_nibble_first": False,
        },
        "modes": [
            {"id": "overview", "name": "总览模式", "description": "查看整体情况、进度与消息",
             "screens": [
                 {"number": 1, "url": "https://example.com/?page=overview"},
                 {"number": 2, "url": "https://example.com/?page=progress"},
                 {"number": 3, "url": "https://example.com/?page=messages"}]},
            {"id": "production", "name": "生产模式", "description": "查看生产、设备与质量页面",
             "screens": [
                 {"number": 1, "url": "https://example.com/?page=production"},
                 {"number": 2, "url": "https://example.com/?page=equipment"},
                 {"number": 3, "url": "https://example.com/?page=quality"}]},
            {"id": "demo", "name": "演示模式", "description": "打开介绍、演示和总结页面",
             "screens": [
                 {"number": 1, "url": "https://example.com/?page=intro"},
                 {"number": 2, "url": "https://example.com/?page=demo"},
                 {"number": 3, "url": "https://example.com/?page=summary"}]},
        ],
    }


def validate_screens(items):
    if not isinstance(items, list) or len(items) != 3:
        raise ValueError("必须配置三个屏幕")
    if any(not isinstance(x, dict) or type(x.get("number")) is not int for x in items):
        raise ValueError("屏幕编号必须是整数")
    if {x["number"] for x in items} != {1, 2, 3}:
        raise ValueError("屏幕编号必须为 1、2、3，且不可重复")
    for item in items:
        url = item.get("url")
        if not isinstance(url, str) or len(url) > 8192:
            raise ValueError("页面 URL 无效")
        parsed = urlsplit(url)
        if parsed.scheme not in ("https", "http") or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("页面只接受不含用户名密码的 http / https URL")
    return copy.deepcopy(sorted(items, key=lambda x: x["number"]))


def validate(config, role):
    if not isinstance(config, dict):
        raise ValueError("配置必须为 JSON 对象")
    if not isinstance(config.get("token"), str) or len(config["token"]) < 24:
        raise ValueError("连接密钥至少 24 个字符，两端需填写相同值")
    if not config["token"].isascii() or any(c.isspace() for c in config["token"]):
        raise ValueError("连接密钥请使用不含空白的英文字母、数字或符号")
    if role == "client":
        if not isinstance(config.get("client_id"), str) or not config["client_id"].strip():
            raise ValueError("客户端 ID 不能为空")
        url = urlsplit(config.get("server_url", ""))
        if url.scheme not in ("ws", "wss") or not url.hostname or url.username or url.password:
            raise ValueError("集控地址应为 ws://主机:端口 或 wss://主机:端口")
        if url.path not in ("", "/") or url.query or url.fragment:
            raise ValueError("集控地址只填写主机和端口，例如 ws://192.168.1.10:8765")
        validate_screens(config.get("screens"))
        if type(config.get("fullscreen")) is not bool or not isinstance(config.get("chrome_path"), str):
            raise ValueError("fullscreen 必须为 true / false，chrome_path 必须为字符串")
        if any(not isinstance(x.get("display_name", ""), str) for x in config["screens"]):
            raise ValueError("display_name 必须是字符串")
    else:
        if not isinstance(config.get("host"), str) or not config["host"].strip():
            raise ValueError("集控监听地址不能为空")
        if type(config.get("port")) is not int or not 1 <= config["port"] <= 65535:
            raise ValueError("端口应在 1 到 65535 之间")
        targets = config.get("target_clients")
        if not isinstance(targets, list) or not targets or any(not isinstance(x, str) or not x for x in targets):
            raise ValueError("请指定至少一个目标客户端 ID")
        modes = config.get("modes")
        if not isinstance(modes, list) or not modes:
            raise ValueError("至少配置一个模式")
        ids = set()
        for mode in modes:
            if not isinstance(mode, dict) or not isinstance(mode.get("id"), str) or not mode["id"] or mode["id"] in ids:
                raise ValueError("模式 ID 不能为空或重复")
            ids.add(mode["id"])
            if not isinstance(mode.get("name"), str) or not mode["name"]:
                raise ValueError("模式名称不能为空")
            validate_screens(mode.get("screens"))
        voice = config.get("voice", {})
        if not isinstance(voice, dict) or any(not isinstance(voice.get(key), str) for key in ("remote_address", "virtual_output", "shortcut")):
            raise ValueError("遥控器地址、虚拟设备名、快捷键必须为字符串")
        if not voice["shortcut"].strip():
            raise ValueError("输入法快捷键不能为空")
        if any(type(voice.get(key)) is not bool for key in ("auto_submit", "low_nibble_first")):
            raise ValueError("auto_submit 和 low_nibble_first 必须为 true / false")
        if voice.get("trigger") not in ("hold", "toggle"):
            raise ValueError("语音快捷键触发方式必须为 hold 或 toggle")
        if type(voice.get("settle_ms")) is not int or not 500 <= voice["settle_ms"] <= 15000:
            raise ValueError("文字稳定等待时间应为 500 至 15000 毫秒")
        dsh = config.get("dsh", {})
        if not isinstance(dsh, dict):
            raise ValueError("dsh 配置必须为对象")
        if not isinstance(dsh.get("executable"), str) or not dsh["executable"].strip():
            raise ValueError("请配置 dsh 可执行文件路径")
        if type(dsh.get("timeout_seconds")) is not int or not 5 <= dsh["timeout_seconds"] <= 600:
            raise ValueError("dsh 超时应为 5 至 600 秒")
    return config


def save(path, config, role):
    validate(config, role)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(config, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load(path, role):
    if not path.exists():
        save(path, default_config(role), role)
    return validate(json.loads(path.read_text(encoding="utf-8")), role)
