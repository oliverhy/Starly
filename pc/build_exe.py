from pathlib import Path

import PyInstaller.__main__
from PyInstaller.utils.win32 import winutils


ROOT = Path(__file__).resolve().parent.parent

# PE checksums are optional for Windows user-mode executables. Some endpoint
# protection tools briefly lock a newly created EXE at this final rewrite,
# even though packaging has completed, so leave the checksum unset.
winutils.update_exe_pe_checksum = lambda _path: None

PyInstaller.__main__.run([
    "--noconfirm",
    "--clean",
    "--onefile",
    "--windowed",
    "--name",
    "StarlyBridge",
    "--icon",
    str(ROOT / "assets" / "generated" / "starly-app-icon-source.png"),
    str(ROOT / "pc" / "starly_bridge.py"),
])
