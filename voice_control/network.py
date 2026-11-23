import asyncio
import json
import secrets
from collections import OrderedDict
from http import HTTPStatus

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

from .protocol import command, decode, encode, validate_command


class ControllerServer:
    def __init__(self, config, log):
        self.config, self.log = config, log
        self.clients = {}
        self.pending = {}
        self.server = None

    def authorize(self, connection, request):
        values = request.headers.get_all("Authorization")
        expected = "Bearer " + self.config["token"]
        if request.path != "/control" or len(values) != 1 or not secrets.compare_digest(values[0], expected):
            return connection.respond(HTTPStatus.UNAUTHORIZED, "Unauthorized\n")

    async def start(self):
        self.server = await serve(
            self.handle, self.config["host"], self.config["port"],
            process_request=self.authorize, origins=[None],
            max_size=65536, max_queue=16, ping_interval=10, ping_timeout=10,
        )
        self.log(f"控制服务已启动，端口 {self.config['port']}")

    async def handle(self, socket):
        client_id = None
        try:
            hello = decode(await asyncio.wait_for(socket.recv(), 5))
            client_id = hello.get("client_id")
            if hello.get("type") != "hello" or not isinstance(client_id, str) or not client_id or len(client_id) > 100:
                raise ValueError("客户端身份格式无效")
            if client_id in self.clients:
                await socket.close(1008, "Duplicate client ID")
                return
            self.clients[client_id] = socket
            await socket.send(encode("welcome", client_id=client_id))
            self.log(f"客户端上线：{client_id}；屏幕：{hello.get('displays', [])}")
            async for raw in socket:
                message = decode(raw)
                if message.get("type") == "result":
                    key = (client_id, message.get("id"))
                    future = self.pending.get(key)
                    if future and not future.done():
                        future.set_result(message)
        except (ConnectionClosed, asyncio.TimeoutError):
            pass
        except Exception as exc:
            self.log(f"客户端通信：{exc}")
            await socket.close(1008, "Invalid message")
        finally:
            if self.clients.get(client_id) is socket:
                del self.clients[client_id]
                self.log(f"客户端离线：{client_id}")
                for (owner, _), future in list(self.pending.items()):
                    if owner == client_id and not future.done():
                        future.set_exception(RuntimeError(f"客户端 {client_id} 已断开，执行结果未知"))

    async def dispatch(self, mode):
        targets = list(dict.fromkeys(self.config["target_clients"]))
        missing = [x for x in targets if x not in self.clients]
        if missing:
            raise RuntimeError("目标客户端未上线：" + "、".join(missing))
        payload = command(mode)
        async def send(client_id):
            key = (client_id, payload["id"])
            future = asyncio.get_running_loop().create_future()
            self.pending[key] = future
            try:
                await self.clients[client_id].send(encode("set_mode", **payload))
                result = await asyncio.wait_for(future, 65)
                self.log(f"{client_id}：{json.dumps(result, ensure_ascii=False)}")
                return result.get("ok") is True
            except Exception as exc:
                self.log(f"{client_id}：{exc}；不自动重发，请检查客户端")
                return False
            finally:
                self.pending.pop(key, None)
        results = await asyncio.gather(*(send(x) for x in targets))
        if not all(results):
            raise RuntimeError("部分屏幕执行失败或结果未知，请查看逐屏回执")
        self.log(f"所有目标客户端已完成：{mode['name']}")

    async def close(self):
        if self.server:
            self.server.close()
            await self.server.wait_closed()


async def run_client(config, browser, displays, log):
    cache = OrderedDict()
    url = config["server_url"].rstrip("/") + "/control"
    delay = 1
    while True:
        try:
            log("正在连接集控端…")
            async with connect(url, additional_headers={"Authorization": "Bearer " + config["token"]},
                               max_size=65536, ping_interval=10, ping_timeout=10) as socket:
                await socket.send(encode("hello", client_id=config["client_id"], displays=displays()))
                welcome = decode(await asyncio.wait_for(socket.recv(), 5))
                if welcome.get("type") != "welcome":
                    raise RuntimeError("集控端握手失败")
                log("已连接集控端")
                delay = 1
                async for raw in socket:
                    message = decode(raw)
                    if message.get("type") != "set_mode":
                        raise ValueError("未知消息类型")
                    request_id = message.get("id")
                    if not isinstance(request_id, str) or len(request_id) > 100:
                        raise ValueError("指令 ID 无效")
                    if request_id in cache:
                        await socket.send(cache[request_id])
                        continue
                    try:
                        screens = validate_command(message)
                        results = await asyncio.wait_for(browser.apply(screens), 60)
                        response = encode("result", id=request_id, ok=all(x["ok"] for x in results), screens=results)
                    except Exception as exc:
                        response = encode("result", id=request_id, ok=False, error=str(exc)[:1000])
                    cache[request_id] = response
                    while len(cache) > 256:
                        cache.popitem(last=False)
                    log(response)
                    await socket.send(response)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log(f"连接中断：{exc}；{delay} 秒后重连，当前页面保持显示")
        await asyncio.sleep(delay)
        delay = min(delay * 2, 15)
