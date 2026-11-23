#!/usr/bin/env python3
"""用实际 iTerm2 分屏验证生产 AppleScript，不编译 Swift、不输入终端命令。"""
import pathlib
import re
import subprocess


def run(source):
    result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "无法访问 iTerm2，请检查自动化权限。")
    return result.stdout.strip()


def tell(source):
    return 'tell application id "com.googlecode.iterm2"\n' + source + '\nend tell'


def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    if run('application id "com.googlecode.iterm2" is running') != "true":
        raise SystemExit("请先启动 iTerm2，并打开至少两个分屏。")
    path = pathlib.Path(__file__).resolve().parents[1] / "Sources/RemoteVibe/ActionPerformer.swift"
    match = re.search(r'let paneScript = [^\n]*\? """\n(.*?)\n\s*""" : ""', path.read_text(), re.S)
    if not match:
        raise SystemExit("找不到生产分屏脚本，请检查 ActionPerformer.swift。")
    template = match.group(1)
    count = int(run(tell('return count of sessions of current tab of current window')))
    if count < 2:
        raise SystemExit("当前标签页至少需要两个分屏；检查不会自动创建分屏。")
    current = 'return unique id of current session of current tab of current window'
    initial = run(tell(current))
    window = run(tell('return id of current window'))
    tab = run(tell('return index of current tab of current window'))

    def move(direction):
        source = template.replace(r'\(paneDirection)', str(direction))
        if r'\(' in source:
            raise RuntimeError("生产脚本出现了新的 Swift 插值，请更新检查脚本。")
        run(tell(source))
        if run(tell('return id of current window')) != window or run(tell('return index of current tab of current window')) != tab:
            raise AssertionError("分屏切换改变了窗口或标签页。")
        return run(tell(current))

    try:
        for direction in (1, -1):
            seen = {initial}
            for step in range(1, count + 1):
                active = move(direction)
                if step == count:
                    assert active == initial, "没有循环回到起始分屏。"
                else:
                    assert active not in seen, "尚未遍历全部分屏就出现重复。"
                    seen.add(active)
        print(f"通过：{count} 个分屏正反循环，窗口和标签页保持不变。")
    finally:
        run(tell('tell current tab of window id ' + window + '\nrepeat with pane in sessions\nif unique id of pane is ' + quote(initial) + ' then\ntell pane to select\nexit repeat\nend if\nend repeat\nend tell'))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AssertionError) as error:
        raise SystemExit(str(error))
