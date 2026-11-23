import asyncio
from pathlib import Path

from playwright.async_api import async_playwright

from .config import data_dir, validate_screens


class ChromeScreens:
    def __init__(self, config, displays):
        self.config, self.displays = config, displays
        self.playwright = None
        self.contexts = {}
        self.pages = {}

    def targets(self, screens):
        screens = validate_screens(screens)
        displays = self.displays()
        result = []
        used = set()
        for item in screens:
            local = next(x for x in self.config["screens"] if x["number"] == item["number"])
            name = local.get("display_name", "")
            matches = [x for x in displays if x["name"] == name] if name else displays[item["number"]-1:item["number"]]
            if len(matches) != 1:
                raise RuntimeError(f"{item['number']} 号屏幕未连接或名称不唯一，请检查屏幕配置")
            display = matches[0]
            if display["index"] in used:
                raise RuntimeError("三个逻辑屏幕不能映射到同一块显示器")
            used.add(display["index"])
            result.append((item, display))
        return result

    async def apply(self, screens):
        targets = self.targets(screens)  # 先验证全部映射，避免缺屏时启动一半。
        if not self.playwright:
            self.playwright = await async_playwright().start()
        results = []
        # 顺序执行并记录逐屏结果；网页失败不应阻止其余屏幕执行。
        for item, display in targets:
            number = item["number"]
            try:
                await self.navigate(number, item["url"], display)
                results.append({"number": number, "ok": True, "url": item["url"]})
            except Exception as exc:
                results.append({"number": number, "ok": False, "error": str(exc)[:1000]})
        return results

    async def navigate(self, number, url, display):
        page = self.pages.get(number)
        context = self.contexts.get(number)
        if page is None or page.is_closed():
            if context:
                try:
                    await context.close()
                except Exception:
                    pass
            profile = data_dir() / "chrome" / f"screen-{number}"
            profile.mkdir(parents=True, exist_ok=True)
            options = {
                "headless": False, "no_viewport": True,
                "args": [f"--window-position={display['x']},{display['y']}",
                         f"--window-size={display['width']},{display['height']}", "--no-first-run"],
            }
            executable = self.config.get("chrome_path", "").strip()
            if executable:
                if not Path(executable).is_file():
                    raise RuntimeError("配置的 Chrome 可执行文件不存在")
                options["executable_path"] = executable
            else:
                options["channel"] = "chrome"
            context = await self.playwright.chromium.launch_persistent_context(str(profile), **options)
            self.contexts[number] = context
            page = context.pages[0] if context.pages else await context.new_page()
            self.pages[number] = page
            for extra in list(context.pages):
                if extra != page:
                    await extra.close()
        session = await context.new_cdp_session(page)
        try:
            window = await session.send("Browser.getWindowForTarget")
            window_id = window["windowId"]
            await session.send("Browser.setWindowBounds", {"windowId": window_id, "bounds": {"windowState": "normal"}})
            await self.wait_bounds(session, window_id, lambda b: b.get("windowState") == "normal")
            await session.send("Browser.setWindowBounds", {
                "windowId": window_id, "bounds": {"left": display["x"], "top": display["y"],
                "width": display["width"], "height": display["height"]},
            })
            await self.wait_bounds(session, window_id, lambda b:
                display["x"] <= b.get("left", 0) + b.get("width", 0) / 2 < display["x"] + display["width"]
                and display["y"] <= b.get("top", 0) + b.get("height", 0) / 2 < display["y"] + display["height"])
            # Windows / macOS 实际全屏与屏幕编号需在目标机器验收。
            if self.config.get("fullscreen", True):
                await session.send("Browser.setWindowBounds", {"windowId": window_id, "bounds": {"windowState": "fullscreen"}})
                await self.wait_bounds(session, window_id, lambda b: b.get("windowState") == "fullscreen")
            await page.goto(url, wait_until="domcontentloaded", timeout=15000)
        finally:
            await session.detach()

    async def wait_bounds(self, session, window_id, matches):
        for _ in range(20):
            result = await session.send("Browser.getWindowBounds", {"windowId": window_id})
            if matches(result["bounds"]):
                return
            await asyncio.sleep(0.1)
        raise RuntimeError("Chrome 未进入指定屏幕位置或窗口状态，请检查系统的显示与全屏设置")

    async def close(self):
        for context in self.contexts.values():
            try:
                await context.close()
            except Exception:
                pass
        self.contexts.clear()
        self.pages.clear()
        if self.playwright:
            await self.playwright.stop()
            self.playwright = None
