import asyncio
import unittest

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import InvalidStatus

from voice_control.config import default_config
from voice_control.network import ControllerServer, run_client
from voice_control.protocol import command, decode, encode


class FakeBrowser:
    def __init__(self):
        self.calls = []

    async def apply(self, screens):
        self.calls.append(screens)
        return [{"number": x["number"], "ok": True} for x in screens]


class NetworkTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.config = default_config("controller")
        self.config.update(host="127.0.0.1", port=0)
        self.server = ControllerServer(self.config, lambda _: None)
        await self.server.start()
        port = self.server.server.sockets[0].getsockname()[1]
        self.url = f"ws://127.0.0.1:{port}"

    async def asyncTearDown(self):
        await self.server.close()

    async def test_reject_wrong_token_and_browser_origin(self):
        for headers, origin in (({"Authorization": "Bearer wrong"}, None),
                                ({"Authorization": "Bearer " + self.config["token"]}, "https://example.com")):
            with self.assertRaises(InvalidStatus):
                async with connect(self.url + "/control", additional_headers=headers, origin=origin):
                    pass

    async def test_real_websocket_dispatch_and_receipt(self):
        config = default_config("client")
        config.update(server_url=self.url, token=self.config["token"])
        browser = FakeBrowser()
        client_task = asyncio.create_task(run_client(config, browser, lambda: [], lambda _: None))
        try:
            async with asyncio.timeout(3):
                while "display-01" not in self.server.clients:
                    await asyncio.sleep(0.01)
                await self.server.dispatch(self.config["modes"][0])
            self.assertEqual(len(browser.calls), 1)
            self.assertEqual(browser.calls[0][0]["url"], self.config["modes"][0]["screens"][0]["url"])
        finally:
            client_task.cancel()
            await asyncio.gather(client_task, return_exceptions=True)

    async def test_missing_client_never_broadcasts(self):
        with self.assertRaisesRegex(RuntimeError, "未上线"):
            await self.server.dispatch(self.config["modes"][0])

    async def test_duplicate_id_does_not_disconnect_original(self):
        headers = {"Authorization": "Bearer " + self.config["token"]}
        async with connect(self.url + "/control", additional_headers=headers) as first:
            await first.send(encode("hello", client_id="display-01"))
            self.assertEqual(decode(await first.recv())["type"], "welcome")
            async with connect(self.url + "/control", additional_headers=headers) as second:
                await second.send(encode("hello", client_id="display-01"))
                await second.wait_closed()
                self.assertEqual(second.close_code, 1008)
            self.assertIn("display-01", self.server.clients)

    async def test_client_deduplicates_same_command(self):
        complete = asyncio.Event()
        replies = []
        async def handler(socket):
            await socket.recv()
            await socket.send(encode("welcome"))
            payload = encode("set_mode", **command(self.config["modes"][0]))
            for _ in range(2):
                await socket.send(payload)
                replies.append(decode(await socket.recv()))
            complete.set()
            await socket.wait_closed()

        async with serve(handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            config = default_config("client")
            config["server_url"] = f"ws://127.0.0.1:{port}"
            browser = FakeBrowser()
            task = asyncio.create_task(run_client(config, browser, lambda: [], lambda _: None))
            try:
                await asyncio.wait_for(complete.wait(), 3)
                self.assertEqual(len(browser.calls), 1)
                self.assertEqual(replies[0], replies[1])
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
