#!/usr/bin/env python3
# Builds packaging/kirc.ico from the existing hicolor PNG artwork.
#
# Writes a modern ICO whose entries are the PNGs themselves (valid for every
# Windows since Vista) — no re-encoding, so the embedded artwork stays
# byte-identical to the Linux icon theme set.
#
# Usage: python packaging/make-ico.py [outfile]

import struct
import sys
from pathlib import Path

SIZES = [16, 24, 32, 48, 64, 128, 256]


def main() -> int:
    repo = Path(__file__).resolve().parent
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "kirc.ico"

    blobs = []
    for size in SIZES:
        png = repo / "icons" / "hicolor" / f"{size}x{size}" / "apps" / "kirc.png"
        blobs.append(png.read_bytes())

    with out.open("wb") as f:
        # ICONDIR: reserved, type=1 (icon), entry count
        f.write(struct.pack("<HHH", 0, 1, len(blobs)))
        offset = 6 + 16 * len(blobs)
        for size, blob in zip(SIZES, blobs):
            # ICONDIRENTRY: width (0 means 256), height, color count,
            # reserved, planes, bit count, blob size, blob offset
            f.write(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset))
            offset += len(blob)
        for blob in blobs:
            f.write(blob)

    print(f"wrote {out} ({out.stat().st_size} bytes, {len(blobs)} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
