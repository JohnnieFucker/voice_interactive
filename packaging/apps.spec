# 在目标系统执行：pyinstaller --noconfirm packaging/apps.spec
import os
import sys
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_submodules

root = Path(SPECPATH).parent
datas, binaries, hidden = collect_all("playwright")
# pynput 按平台动态选择后端，不能仅依赖静态 import 分析。
hidden += collect_submodules("pynput") + collect_submodules("bleak.backends")
notices = [(str(root / "LICENSE"), "."), (str(root / "THIRD_PARTY_NOTICES.md"), ".")]

for role, name in (("controller", "VoiceController"), ("client", "ScreenClient")):
    analysis = Analysis(
        [str(root / "packaging" / f"{role}.py")], pathex=[str(root)],
        binaries=binaries, datas=datas + notices + [(str(root / "voice_control/assets"), "voice_control/assets")], hiddenimports=hidden,
        excludes=["tkinter", "PyQt5", "PyQt6"],
    )
    pyz = PYZ(analysis.pure)
    executable = EXE(
        pyz, analysis.scripts, [], exclude_binaries=True, name=name,
        console=False, debug=False,
        codesign_identity=os.environ.get("CODE_SIGN_IDENTITY") or None,
    )
    collection = COLLECT(executable, analysis.binaries, analysis.datas, name=name)
    if sys.platform == "darwin":
        BUNDLE(
            collection, name=f"{name}.app", bundle_identifier=f"dev.voicescreen.{role}",
            info_plist={
                "CFBundleDisplayName": "语音集控端" if role == "controller" else "三屏客户端",
                "CFBundleShortVersionString": "0.1.0",
                "NSHighResolutionCapable": True,
                "NSBluetoothAlwaysUsageDescription": "连接已配对的小米遥控器并接收语音音频。",
                "LSMinimumSystemVersion": "13.0",
            },
        )
