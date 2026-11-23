"""为 dsh 安装独立 Node 24 LTS，不修改系统 Node 或全局 npm 配置。"""
import asyncio
import hashlib
import json
import os
import platform
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

from .config import data_dir


def node_path():
    return data_dir() / "runtime/node" / ("node.exe" if os.name == "nt" else "bin/node")


def download(url, destination):
    with urllib.request.urlopen(url, timeout=45) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def install_node():
    system = "win" if os.name == "nt" else "darwin"
    machine = platform.machine().lower()
    architecture = {"arm64": "arm64", "aarch64": "arm64", "amd64": "x64", "x86_64": "x64"}.get(machine)
    if not architecture or platform.system() not in ("Darwin", "Windows"):
        raise RuntimeError("自动安装 Node 仅支持 macOS / Windows 的 x64 与 arm64")
    directory = data_dir() / "runtime"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory, prefix="node-download-") as temporary:
        stage = Path(temporary)
        index = stage / "index.json"
        download("https://nodejs.org/dist/index.json", index)
        release = next((r for r in json.loads(index.read_text()) if r["version"].startswith("v24.") and r.get("lts")), None)
        if release is None:
            raise RuntimeError("官方源未返回 Node 24 LTS，请稍后重试")
        version = release["version"]
        folder = f"node-{version}-{system}-{architecture}"
        filename = folder + (".zip" if system == "win" else ".tar.gz")
        base = f"https://nodejs.org/dist/{version}/"
        checksum = stage / "SHASUMS256.txt"
        download(base + "SHASUMS256.txt", checksum)
        expected = next((line.split()[0] for line in checksum.read_text().splitlines()
                         if len(line.split()) == 2 and line.split()[1] == filename), None)
        if expected is None:
            raise RuntimeError("官方校验清单中未找到所需 Node 安装文件")
        archive = stage / filename
        download(base + filename, archive)
        with archive.open("rb") as source:
            actual = hashlib.file_digest(source, "sha256").hexdigest()
        if actual != expected:
            raise RuntimeError("Node 文件校验失败，已停止安装")
        if system == "win":
            with zipfile.ZipFile(archive) as source:
                for name in source.namelist():
                    path = PurePosixPath(name)
                    if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
                        raise RuntimeError("Node 压缩文件中包含非法路径")
                source.extractall(stage)
        else:
            with tarfile.open(archive) as source:
                source.extractall(stage, filter="data")
        target = directory / "node"
        if target.exists():
            raise RuntimeError("独立 Node 目录已存在但版本不适用，请检查 runtime/node 后重试")
        (stage / folder).rename(target)
    return node_path()


async def ensure_node():
    from .dsh import find_program, run_process
    candidate = str(node_path()) if node_path().is_file() else find_program("node.exe" if os.name == "nt" else "node")
    if candidate:
        code, output, _ = await run_process([candidate, "--version"], timeout=10)
        try:
            version = tuple(int(x) for x in output.strip().removeprefix("v").split(".")[:2])
        except ValueError:
            version = (0, 0)
        if not code and version >= (24, 9):
            return Path(candidate)
    return await asyncio.to_thread(install_node)
