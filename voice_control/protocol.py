import json
import time
import uuid

from .config import validate_screens

VERSION = 1


def decode(raw):
    message = json.loads(raw)
    if not isinstance(message, dict) or message.get("version") != VERSION:
        raise ValueError("消息格式或协议版本不匹配")
    return message


def encode(kind, **fields):
    return json.dumps({"version": VERSION, "type": kind, **fields}, ensure_ascii=False)


def command(mode):
    return {
        "id": str(uuid.uuid4()), "mode_id": mode["id"],
        "expires_at": time.time() + 30,
        "screens": validate_screens(mode["screens"]),
    }


def validate_command(message):
    if message.get("type") != "set_mode" or not isinstance(message.get("id"), str):
        raise ValueError("不支持的控制指令")
    deadline = message.get("expires_at")
    if type(deadline) not in (int, float) or not time.time() < deadline <= time.time() + 60:
        raise ValueError("指令已过期或有效期无效，请检查两端系统时间")
    return validate_screens(message.get("screens"))
