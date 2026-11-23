import asyncio
import threading
import time
import sys

class InputMethod:
    """把遥控器 PCM 写入明确选定的虚拟输出，快捷键由已安装输入法识别。"""
    def __init__(self, config):
        self.config = config
        self.stream = None
        self.pending = bytearray()
        self.lock = threading.Lock()
        self.keyboard = None
        self.keys = []
        self.held = []
        self.toggled = False
        self.audio_fault = None

    def start(self):
        import sounddevice as sd
        from pynput.keyboard import Controller, HotKey
        if sys.platform == "darwin":
            from Quartz import AXIsProcessTrusted
            if not AXIsProcessTrusted():
                raise RuntimeError("请先在系统设置的“辅助功能”中授权集控端发送快捷键")
        self.keyboard = Controller()
        self.keys = HotKey.parse(self.config["shortcut"])
        name = self.config.get("virtual_output", "").strip()
        if not name:
            raise RuntimeError("请配置 voice.virtual_output，并在语音输入法选择对应虚拟输入设备")
        if not any(marker in name.lower() for marker in ("blackhole", "miremotev", "cable input")):
            raise RuntimeError("仅允许输出到 BlackHole、MiRemoteV 或 VB-CABLE 的 CABLE Input，避免播放到扬声器")
        # 不接受系统默认设备，也不回退到扬声器。用户需明确指定虚拟设备完整名称。
        devices = sd.query_devices()
        matches = [i for i, d in enumerate(devices) if d["name"] == name and d["max_output_channels"] >= 2]
        if len(matches) != 1:
            raise RuntimeError("虚拟输出设备不存在或名称不唯一，请使用“音频设备”列表中的完整名称")
        with self.lock:
            self.pending.clear()
        self.audio_fault = None
        self.stream = sd.RawOutputStream(
            device=matches[0], samplerate=16000, channels=2, dtype="int16",
            blocksize=320, callback=self.output,
        )
        try:
            self.stream.start()
            self.press()
            if self.config["trigger"] == "toggle":
                self.release()
                self.toggled = True
        except BaseException:
            self.abort()
            raise

    def press(self):
        for key in self.keys:
            self.keyboard.press(key)
            self.held.append(key)

    def release(self):
        failures = []
        while self.held:
            key = self.held.pop()
            try:
                self.keyboard.release(key)
            except Exception as exc:
                failures.append(exc)
        if failures:
            raise RuntimeError("语音快捷键释放失败，请检查系统权限") from failures[0]

    def write(self, pcm):
        if self.audio_fault:
            raise RuntimeError(self.audio_fault)
        stereo = bytearray()
        for i in range(0, len(pcm), 2):
            stereo.extend(pcm[i:i+2] * 2)
        with self.lock:
            if len(self.pending) + len(stereo) > 16000 * 4 * 3:
                raise RuntimeError("虚拟音频积压超过 3 秒，已取消语音")
            self.pending.extend(stereo)

    def output(self, outdata, frames, timing, status):
        if status:
            self.audio_fault = f"虚拟音频设备异常：{status}"
        with self.lock:
            amount = min(len(outdata), len(self.pending))
            data = bytes(self.pending[:amount])
            del self.pending[:amount]
        outdata[:] = data + bytes(len(outdata) - amount)

    async def finish(self, cancelled=False, can_toggle=True):
        try:
            if not cancelled and self.stream:
                deadline = time.monotonic() + 4
                while self.pending and time.monotonic() < deadline:
                    await asyncio.sleep(0.02)
                await asyncio.sleep(min(float(self.stream.latency), 0.5))
        finally:
            self.abort(can_toggle=can_toggle)
        if self.audio_fault:
            raise RuntimeError(self.audio_fault)

    def abort(self, can_toggle=True):
        if callable(can_toggle):
            can_toggle = can_toggle()
        try:
            self.release()
            if self.toggled:
                self.toggled = False
                if can_toggle:
                    try:
                        self.press()
                    finally:
                        self.release()
                else:
                    raise RuntimeError("焦点已离开集控输入框，请在语音输入法中手动结束识别")
        finally:
            if self.stream:
                stream = self.stream
                self.stream = None
                try:
                    stream.abort()
                finally:
                    stream.close()
            with self.lock:
                self.pending.clear()


def audio_devices():
    import sounddevice as sd
    return "\n".join(
        f"{i}: {d['name']}（输入 {d['max_input_channels']} / 输出 {d['max_output_channels']}）"
        for i, d in enumerate(sd.query_devices())
    )
