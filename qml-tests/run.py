#!/usr/bin/env python3
"""Cross-platform runner for the QML contract harnesses."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
QMLDIR = """module org.kde.kirc
singleton ThemeEngine 1.0 ThemeEngine.qml
IrcBridge 1.0 IrcBridge.qml
MessageListModel 1.0 MessageListModel.qml
ChatPage 1.0 ChatPage.qml
ConnectPage 1.0 ConnectPage.qml
MessageDelegate 1.0 MessageDelegate.qml
GlassSurface 1.0 GlassSurface.qml
ScanlineOverlay 1.0 ScanlineOverlay.qml
"""


def find_qml(explicit: str | None) -> Path:
    candidates = [explicit, os.environ.get("QML_BIN")]
    craft = os.environ.get("KIRC_CRAFT_ROOT")
    if craft:
        candidates.append(str(Path(craft) / "bin" / "qml.exe"))
    candidates.extend([shutil.which("qml6"), shutil.which("qml")])
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    raise SystemExit("run.py: qml executable not found; pass --qml-bin or set QML_BIN")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qml-bin")
    parser.add_argument("--stage", choices=("all", "tokens", "smoke", "cmds", "scroll", "glass"), default="all")
    parser.add_argument("--qpa", default=os.environ.get("QPA", "offscreen"))
    args = parser.parse_args()
    stages = ("tokens", "smoke", "cmds", "scroll", "glass") if args.stage == "all" else (args.stage,)
    qml = None if stages == ("tokens",) else find_qml(args.qml_bin)
    status = 0

    with tempfile.TemporaryDirectory(prefix="kirc-qml-") as temporary:
        temp = Path(temporary)
        module = temp / "org" / "kde" / "kirc"
        module.mkdir(parents=True)
        for source in (ROOT / "rust" / "qml").glob("*.qml"):
            shutil.copy2(source, module)
        shutil.copy2(ROOT / "rust" / "qml" / "Theme.js", module)
        shutil.copytree(ROOT / "rust" / "qml" / "themes", module / "themes")
        for name in ("IrcBridge.qml", "MessageListModel.qml"):
            shutil.copy2(HERE / name, module)
        (module / "qmldir").write_text(QMLDIR, encoding="utf-8", newline="\n")
        for name in ("tst_smoke.qml", "tst_cmds.qml", "tst_scroll.qml", "tst_glass.qml"):
            shutil.copy2(HERE / name, temp)

        env = os.environ.copy()
        old_import = env.get("QML2_IMPORT_PATH", "")
        env["QML2_IMPORT_PATH"] = str(temp) + (os.pathsep + old_import if old_import else "")
        env.update(QT_FORCE_STDERR_LOGGING="1", QT_QPA_PLATFORM=args.qpa,
                   QT_QUICK_CONTROLS_STYLE="Basic")
        harness = {"smoke": "tst_smoke.qml", "cmds": "tst_cmds.qml",
                   "scroll": "tst_scroll.qml", "glass": "tst_glass.qml"}
        for stage in stages:
            command = ([sys.executable, str(HERE / "check-theme-tokens.py")] if stage == "tokens"
                       else [str(qml), str(temp / harness[stage])])
            print(f"== QML stage: {stage} ==", flush=True)
            try:
                result = subprocess.run(command, env=env, timeout=180, check=False)
            except subprocess.TimeoutExpired:
                print(f"run.py: {stage} timed out", file=sys.stderr)
                status = 1
                continue
            if result.returncode:
                status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
