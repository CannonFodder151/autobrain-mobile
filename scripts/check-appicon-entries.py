#!/usr/bin/env python3
"""Verify every AppIcon.appiconset manifest entry resolves to a file with the exact pixel size actool requires."""
import json, struct, sys, os

ICONSET = "ios/Runner/Assets.xcassets/AppIcon.appiconset"

with open(os.path.join(ICONSET, "Contents.json")) as f:
    images = json.load(f)["images"]

required_pixel = {}  # (size, scale) -> pixel dimension
fail = False
for entry in images:
    size = entry["size"]
    scale = int(entry["scale"][0])
    w, h = (float(x) for x in size.split("x"))
    px = w * scale
    # actool convention: Icon-App-<size>@<scale>.png
    name = f"Icon-App-{size}@{entry['scale']}.png"
    path = os.path.join(ICONSET, name)
    if not os.path.exists(path):
        print(f"MISSING FILE: {name} (declared {size} {entry['scale']})")
        fail = True
        continue
    with open(path, "rb") as fh:
        data = fh.read()
    fw, fh_ = struct.unpack(">II", data[16:24])
    if (fw, fh_) != (px, px):
        print(f"SIZE MISMATCH: {name} is {fw}x{fh_}, expected {px}x{px}")
        fail = True
    else:
        print(f"ok: {name} = {fw}x{fh_}")

# iPad support requires these entries to exist at all
ipad = {(e["size"], e["scale"]) for e in images if e["idiom"] == "ipad"}
need = {("76x76", "1x"), ("76x76", "2x"), ("83.5x83.5", "2x"), ("152x152", "2x"), ("167x167", "2x")}
missing = need - ipad
if missing:
    print(f"MISSING iPad ENTRIES: {sorted(missing)}")
    fail = True

sys.exit(1 if fail else 0)
