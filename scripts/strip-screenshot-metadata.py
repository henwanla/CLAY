#!/usr/bin/env python3
"""Keep the image data and color information of static README PNGs."""
import argparse
import struct
from pathlib import Path


def strip_png(image: bytes) -> bytes:
    signature = b"\x89PNG\r\n\x1a\n"
    if not image.startswith(signature):
        raise ValueError("not a PNG")
    keep = {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"cHRM", b"gAMA", b"iCCP", b"sBIT", b"sRGB", b"tRNS"}
    result = [signature]
    offset = len(signature)
    while offset + 12 <= len(image):
        size, tag = struct.unpack_from(">I4s", image, offset)
        end = offset + size + 12
        if end > len(image):
            break
        if tag in keep:
            result.append(image[offset:end])
        elif not tag[0] & 0x20:
            raise ValueError("unknown critical PNG chunk")
        if tag == b"IEND" and end == len(image):
            return b"".join(result)
        offset = end
    raise ValueError("truncated PNG or data after IEND")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if any file contains extra metadata")
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.files:
        image = path.read_bytes()
        clean = strip_png(image)
        if clean != image:
            if args.check:
                raise SystemExit(f"Remove extra metadata from {path.name} before publishing.")
            path.write_bytes(clean)


if __name__ == "__main__":
    main()
