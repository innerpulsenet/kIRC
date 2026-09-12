#!/usr/bin/env python3
"""Stamp one normalized release version across every shipped format."""
from __future__ import annotations

import datetime as dt
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def replace(path: Path, pattern: str, value: str, *, count: int = 1) -> None:
    source = path.read_text(encoding="utf-8")
    updated, matches = re.subn(pattern, value, source, count=count, flags=re.MULTILINE)
    if matches != count:
        raise SystemExit(f"set-version: expected {count} match(es) in {path}, found {matches}")
    path.write_text(updated, encoding="utf-8", newline="\n")


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"\d+(?:\.\d+){0,2}", sys.argv[1]):
        print(f"usage: {Path(sys.argv[0]).name} <version> (for example 1.2 or 1.2.3)", file=sys.stderr)
        return 2
    parts = sys.argv[1].split(".")
    version = ".".join(parts + ["0"] * (3 - len(parts)))
    today = dt.datetime.now(dt.timezone.utc)

    for manifest in (ROOT / "rust/Cargo.toml", ROOT / "rust/core/Cargo.toml"):
        replace(manifest, r'^version = "[^"]+"', f'version = "{version}"')
    for lockfile, package in ((ROOT / "rust/Cargo.lock", "kirc"),
                              (ROOT / "rust/core/Cargo.lock", "kirc-core")):
        replace(lockfile,
                rf'(\[\[package\]\]\nname = "{re.escape(package)}"\nversion = ")[^"]+',
                rf'\g<1>{version}')
    replace(ROOT / "CMakeLists.txt", r"^    VERSION \d+\.\d+\.\d+", f"    VERSION {version}")
    replace(ROOT / "packaging/org.kde.kirc.metainfo.xml",
            r'(<release version=")[^"]+(" date=")[^"]+',
            rf'\g<1>{version}\g<2>{today:%Y-%m-%d}')
    replace(ROOT / "packaging/kirc.spec", r"^Version:\s+\S+", f"Version:        {version}")

    spec = ROOT / "packaging/kirc.spec"
    source = spec.read_text(encoding="utf-8")
    if "%changelog" not in source:
        raise SystemExit(f"set-version: no %changelog section in {spec}")
    first = next((line for line in source.split("%changelog", 1)[1].splitlines()
                  if line.startswith("*")), "")
    if f"- {version}-1" not in first:
        entry = f"* {today:%a %b %d %Y} The kIRC Authors <kirc@innerpulse.net> - {version}-1\n- Release {version}"
        source = source.replace("%changelog\n", f"%changelog\n{entry}\n\n", 1)
        spec.write_text(source, encoding="utf-8", newline="\n")
    print(f"kIRC version set to {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
