import asyncio
import unittest

from voice_control.voice import InputMethod


class Keyboard:
    def __init__(self):
        self.pressed = []
        self.released = []

    def press(self, key):
        self.pressed.append(key)

    def release(self, key):
        self.released.append(key)


class Stream:
    latency = 0.05
    closed = False

    def abort(self):
        pass

    def close(self):
        self.closed = True


class VoiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_focus_change_during_drain_never_toggles_other_app(self):
        method = InputMethod({})
        method.keyboard = Keyboard()
        method.keys = ["ctrl", "v"]
        method.stream = Stream()
        method.toggled = True
        focused = True
        task = asyncio.create_task(method.finish(can_toggle=lambda: focused))
        await asyncio.sleep(0.01)
        focused = False
        with self.assertRaisesRegex(RuntimeError, "焦点"):
            await task
        self.assertEqual(method.keyboard.pressed, [])
        self.assertIsNone(method.stream)

    async def test_cancel_releases_all_held_keys_and_closes_stream(self):
        method = InputMethod({})
        method.keyboard = Keyboard()
        method.held = ["ctrl", "alt", "v"]
        stream = method.stream = Stream()
        await method.finish(cancelled=True)
        self.assertEqual(method.keyboard.released, ["v", "alt", "ctrl"])
        self.assertTrue(stream.closed)

    async def test_audio_backlog_rejected_before_growing(self):
        method = InputMethod({})
        method.pending = bytearray(16000 * 4 * 3)
        with self.assertRaisesRegex(RuntimeError, "积压"):
            method.write(b"\x01\x00")
        self.assertEqual(len(method.pending), 16000 * 4 * 3)


if __name__ == "__main__":
    unittest.main()
