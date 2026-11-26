#!/usr/bin/env python3
"""Package the Ubuntu x86-64 GTK preview from explicit build outputs."""

import argparse
import gzip
import hashlib
from io import BytesIO
from pathlib import Path
import re
import struct
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SWIFT_RELEASE = "6.4.3"
MODULES = (
    "clay-desktop.py", "desktop_pac.py", "gnome_pac.py", "kde_pac.py", "session.py",
    "subscription_dialog.py", "subscriptions.py", "tray.py",
)
NOTICES = (
    "swift.txt", "swift-foundation.md", "swift-foundation-NOTICE.txt", "swift-corelibs-foundation.txt",
    "swift-corelibs-libdispatch.txt", "swift-foundation-icu.md", "icu-76.1.txt", "UPSTREAM.md",
)
LAUNCHER = b'''#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")" && pwd -P)
exec /usr/bin/python3 -EsB "$root/lib/clay-desktop.py" "$@" --cli "$root/bin/clay-portable"
'''


def read_elf(path):
    if not path.is_file() or not path.stat().st_mode & 0o100:
        raise SystemExit("Both native build outputs must be executable files.")
    data = path.read_bytes()
    if (len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01" or
            struct.unpack_from("<HHI", data, 16) not in ((2, 62, 1), (3, 62, 1))):
        raise SystemExit("Both native build outputs must be Linux x86-64 ELF files.")
    return data


def package(cli, helper, output):
    version = (ROOT / "VERSION").read_text(encoding="ascii").strip()
    commit = subprocess.check_output(["git", "rev-parse", "--verify", "HEAD"], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("A numeric VERSION and a valid Git commit are required.")
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT):
        raise SystemExit("Build and package from a clean checkout so the printed commit identifies the source.")

    name = f"CLAY-{version}-linux-x64-{commit[:7]}-preview"
    archive = f"{name}.tar.gz"
    instructions = f'''CLAY {version} · Ubuntu 24.04 x86-64 preview
Source commit: {commit}
Swift toolchain: {SWIFT_RELEASE} (statically linked Swift runtime)

Check the archive: sha256sum -c {archive}.sha256
Extract it, enter the extracted directory and run ./start-clay as your user.
System packages: python3-gi gir1.2-gtk-3.0 curl coreutils libstdc++6
Optional tray: gir1.2-ayatanaappindicator3-0.1 and a desktop tray host.
Optional subscriptions: python3-cryptography libsecret-tools and an unlocked Secret Service.
Optional Plasma 6 system PAC: this helper was checked with libkf5configcore5 on Ubuntu 24.04.
See the Linux guide for details, troubleshooting, and how to build a helper with KF6.

Load local nodes or select cached subscription nodes. Select a verified Mihomo executable
and enter its SHA-256. Choose manual proxy or desktop PAC. Stop or Quit restores settings
that CLAY still owns. The unsigned preview contains no Mihomo or personal configuration.

核对 SHA-256 后解压，以普通用户运行 ./start-clay。无需安装 Swift 工具链。
加载本地节点或订阅缓存，选已校验的 Mihomo 并填写其 SHA-256。
可手动接入或启用桌面系统 PAC；停止或退出会恢复仍由 CLAY 管理的设置。
此包是未签名的技术预览，不含 Mihomo 和个人配置。Linux 指南说明系统依赖、
托盘、订阅和 Plasma 辅助程序的适用范围。

https://github.com/henwanla/CLAY/blob/{commit}/Platforms/Linux/README.md
'''
    files = {
        "start-clay": (0o755, LAUNCHER),
        "START-HERE.txt": (0o644, instructions.encode("utf-8")),
        "bin/clay-portable": (0o755, read_elf(cli)),
        "bin/clay-kde-settings": (0o755, read_elf(helper)),
        "licenses/CLAY.txt": (0o644, (ROOT / "LICENSE").read_bytes()),
        "licenses/Yams.txt": (0o644, (ROOT / "Vendor/Yams/LICENSE").read_bytes()),
        "licenses/libyaml.txt": (0o644, (ROOT / "Vendor/Yams/LICENSE-libyaml").read_bytes()),
    }
    for module in MODULES:
        files[f"lib/{module}"] = (0o644, (ROOT / "Platforms/Linux" / module).read_bytes())
    for notice in NOTICES:
        files[f"licenses/Swift/{notice}"] = (0o644, (ROOT / "Vendor/SwiftLinux" / notice).read_bytes())

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output, prefix=".clay-linux-") as workspace:
        draft = Path(workspace) / archive
        checksum = draft.with_suffix(".gz.sha256")
        with draft.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for path, (mode, data) in sorted(files.items()):
                    member = tarfile.TarInfo(f"{name}/{path}")
                    member.mode, member.size = mode, len(data)
                    tar.addfile(member, BytesIO(data))
        with draft.open("rb") as raw:
            digest = hashlib.file_digest(raw, "sha256").hexdigest()
        checksum.write_text(f"{digest}  {archive}\n", encoding="ascii")
        draft.replace(output / draft.name)
        checksum.replace(output / checksum.name)
    return output / archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path, help="Linux x86-64 clay-portable linked with static Swift runtime")
    parser.add_argument("helper", type=Path, help="Linux x86-64 KDE helper")
    parser.add_argument("output", type=Path, help="output directory for the tarball and SHA-256 file")
    options = parser.parse_args()
    print(package(options.cli, options.helper, options.output))
