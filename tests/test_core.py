import asyncio
import copy
import json
import struct
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from voice_control.atvv import Decoder, capabilities
from voice_control.config import default_config, load, save, validate, validate_screens
from voice_control.protocol import command, decode, encode, validate_command
from voice_control import dsh


class CoreTests(unittest.TestCase):
    def test_original_adpcm_vectors_and_sync(self):
        decoder = Decoder()
        self.assertEqual(struct.unpack("<2h", decoder.decode(b"\x77")), (11, 41))
        decoder.reset()
        self.assertEqual(struct.unpack("<2h", decoder.decode(b"\xff")), (-11, -41))
        decoder.reset(32767, 88)
        self.assertEqual(struct.unpack("<2h", decoder.decode(b"\x77")), (32767, 32767))
        decoder.reset(-32768, 88)
        self.assertEqual(struct.unpack("<2h", decoder.decode(b"\xff")), (-32768, -32768))

    def test_nibble_order_matches_reversed_bytes(self):
        self.assertEqual(Decoder().decode(b"\x17\xab"), Decoder(low_first=True).decode(b"\x71\xba"))

    def test_capability_fallback_and_reject_8k(self):
        self.assertEqual(capabilities(bytes([11, 1, 0, 2, 3, 0, 120])), (256, 120))
        self.assertEqual(capabilities(bytes([11, 1, 0, 0, 2, 0, 0, 0, 0])), (256, 120))
        for bad in (b"", bytes([11, 1, 0, 1, 3, 0, 120]), bytes([11, 0, 1, 0, 2, 0, 120])):
            with self.assertRaises(ValueError):
                capabilities(bad)

    def test_config_roundtrip_and_preserve_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "controller.json"
            config = load(path, "controller")
            self.assertEqual(load(path, "controller"), config)
            config["modes"][0]["name"] = "新名称"
            save(path, config, "controller")
            self.assertEqual(load(path, "controller")["modes"][0]["name"], "新名称")
            path.write_text("{broken", encoding="utf-8")
            with self.assertRaises(ValueError):
                load(path, "controller")
            self.assertEqual(path.read_text(), "{broken")

    def test_reject_bad_screens_and_urls(self):
        screens = default_config("client")["screens"]
        for bad in ([], screens[:2], [screens[0]] * 3):
            with self.assertRaises(ValueError):
                validate_screens(bad)
        for url in ("javascript:alert(1)", "file:///etc/passwd", "https://a:b@example.com", "http:///oops"):
            items = copy.deepcopy(screens)
            items[0]["url"] = url
            with self.assertRaises(ValueError):
                validate_screens(items)

    def test_expired_command_cannot_execute(self):
        mode = default_config("controller")["modes"][0]
        message = decode(encode("set_mode", **command(mode)))
        self.assertEqual(len(validate_command(message)), 3)
        for expiry in (time.time() - 1, time.time() + 1000, float("nan")):
            message["expires_at"] = expiry
            with self.assertRaises(ValueError):
                validate_command(message)

    def test_duplicate_modes_and_invalid_token_rejected(self):
        config = default_config("controller")
        config["modes"].append(config["modes"][0])
        with self.assertRaises(ValueError):
            validate(config, "controller")
        config = default_config("client")
        config["token"] = "不支持" * 24
        with self.assertRaises(ValueError):
            validate(config, "client")


class DshTests(unittest.IsolatedAsyncioTestCase):
    async def test_choose_only_configured_mode_and_fail_closed(self):
        config = default_config("controller")
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(dsh, "data_dir", return_value=Path(directory)), patch.object(dsh, "resolve_executable", return_value="dsh"):
                for selected in ("overview", "unknown", None):
                    event = {"type": "final", "reason": "completed", "text": json.dumps({"mode_id": selected})}
                    with patch.object(dsh, "run_process", new=AsyncMock(return_value=(0, json.dumps(event), ""))) as run:
                        if selected == "overview":
                            mode = await dsh.choose_mode("进入总览模式", config)
                            self.assertEqual(mode["id"], "overview")
                            self.assertIn("--permission-mode", run.call_args.args[0])
                        else:
                            with self.assertRaises(RuntimeError):
                                await dsh.choose_mode("进入某个模式", config)
                event["reason"] = "error"
                with patch.object(dsh, "run_process", new=AsyncMock(return_value=(0, json.dumps(event), ""))):
                    with self.assertRaises(RuntimeError):
                        await dsh.choose_mode("进入总览模式", config)

    async def test_subprocess_timeout_ends_child(self):
        import sys
        with self.assertRaises(asyncio.TimeoutError):
            await dsh.run_process([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.1)


if __name__ == "__main__":
    unittest.main()
