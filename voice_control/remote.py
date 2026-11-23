import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

from . import atvv


class Remote:
    def __init__(self, config, on_start, on_audio, on_stop, log):
        self.config = config
        self.on_start, self.on_audio, self.on_stop = on_start, on_audio, on_stop
        self.log = log
        self.client = None
        self.ready = False
        self.streaming = False
        self.session_id = 0
        self.version = 0x100
        self.frame_size = 120
        self.pending = bytearray()
        self.sync = None
        self.decoder = atvv.Decoder(config.get("low_nibble_first", False))
        self.last_stop = 0
        self.started = 0
        self.keepalive = None
        self.failed = None

    async def write(self, data):
        if self.client and self.client.is_connected:
            characteristic = self.client.services.get_characteristic(atvv.TX)
            if characteristic is None:
                raise RuntimeError("遥控器缺少语音命令特征")
            await self.client.write_gatt_char(characteristic, data, response="write-without-response" not in characteristic.properties)

    async def run(self):
        # Windows Qt 主线程可能初始化 STA；Bleak 与 qasync 共用同一 GUI 消息循环。
        if sys.platform == "win32":
            from bleak.backends.winrt.util import allow_sta
            allow_sta()
        while True:
            try:
                self.failed = asyncio.Event()
                disconnected = self.failed
                self.log("正在查找已配对的小米遥控器…")
                address = self.config.get("remote_address", "").strip()
                if address:
                    device = await BleakScanner.find_device_by_address(address, timeout=15)
                else:
                    names = {"mi rc", "xiaomi bluetooth remote 2 pro", "小米蓝牙语音遥控器"}
                    device = await BleakScanner.find_device_by_filter(
                        lambda d, a: (d.name or a.local_name or "").strip().lower() in names
                        or atvv.SERVICE in [s.lower() for s in a.service_uuids], timeout=15,
                    )
                if not device:
                    raise RuntimeError("未找到遥控器，请先在系统设置配对并按键唤醒")
                async with BleakClient(device, disconnected_callback=lambda _, event=disconnected: event.set(), timeout=20) as client:
                    self.client = client
                    self.ready = False
                    self.capability_ready = asyncio.Event()
                    async def control_callback(sender, data):
                        if self.client is client:
                            await self.control(sender, data)
                    def audio_callback(sender, data):
                        if self.client is client:
                            self.audio(sender, data)
                    await client.start_notify(atvv.CONTROL, control_callback)
                    await client.start_notify(atvv.AUDIO, audio_callback)
                    await self.write(atvv.CAPABILITIES)
                    await asyncio.wait_for(self.capability_ready.wait(), 8)
                    if not self.ready:
                        raise RuntimeError("遥控器能力协商失败")
                    self.log(f"遥控器已连接：{device.name or device.address}")
                    await self.failed.wait()
                    raise RuntimeError("遥控器断开或语音链路异常")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.log(f"蓝牙：{exc}；3 秒后重试")
            finally:
                self.ready = False
                self.stop(cancelled=True)
                self.client = None
            await asyncio.sleep(3)

    async def control(self, _, data):
        if not data:
            return
        try:
            code = data[0]
            if code == 0x0B:
                if not self.ready:
                    self.version, self.frame_size = atvv.capabilities(data)
                    self.ready = True
                    self.capability_ready.set()
            elif code == 0x08 and self.ready:
                await self.write(bytes([0x0C, 0]) if self.version >= 0x100 else bytes([0x0C, 0, 2]))
            elif code == 0x04 and self.ready:
                if len(data) >= 3 and data[2] != 2:
                    raise RuntimeError("遥控器切换到不支持的音频格式")
                self.session_id = data[3] if len(data) >= 4 else 0
                self.start()
            elif code == 0:
                self.stop(cancelled=False)
            elif code == 0x0A and self.ready and len(data) >= 7:
                self.sync = (int.from_bytes(data[4:6], "big", signed=True), data[6])
                self.pending.clear()
        except Exception as exc:
            self.log(f"遥控器语音：{exc}")
            self.failed.set()

    def start(self):
        if self.streaming:
            return
        if not self.on_start():
            self.failed.set()
            return
        self.streaming = True
        self.started = time.monotonic()
        self.decoder.reset()
        self.pending.clear()
        self.sync = None
        self.keepalive = asyncio.create_task(self.extend())

    async def extend(self):
        try:
            while self.streaming:
                if time.monotonic() - self.started > 60:
                    raise RuntimeError("单次语音超过 60 秒，已取消")
                if self.version >= 0x100:
                    await self.write(bytes([0x0E, self.session_id]))
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            self.log(str(exc))
            self.failed.set()

    def audio(self, _, data):
        if not self.ready or time.monotonic() - self.last_stop < 0.3:
            return
        try:
            self.start()
            if not self.streaming:
                return
            self.pending.extend(data)
            while len(self.pending) >= self.frame_size:
                frame = bytes(self.pending[:self.frame_size])
                del self.pending[:self.frame_size]
                if self.sync:
                    self.decoder.reset(*self.sync)
                    self.sync = None
                self.on_audio(self.decoder.decode(frame))
        except Exception as exc:
            self.log(f"音频：{exc}")
            self.failed.set()

    def stop(self, cancelled):
        if self.keepalive:
            self.keepalive.cancel()
            self.keepalive = None
        was_streaming = self.streaming
        self.streaming = False
        self.pending.clear()
        self.sync = None
        self.last_stop = time.monotonic()
        if was_streaming:
            self.on_stop(cancelled)

    async def close(self):
        self.ready = False
        try:
            if self.client and self.client.is_connected:
                await self.write(bytes([0x0D, self.session_id]) if self.version >= 0x100 else bytes([0x0D]))
        finally:
            self.stop(cancelled=True)
