#!/usr/bin/env python3
"""Verify every AppIcon.appiconset manifest entry names a file with the exact pixel size actool requires.

An entry without a "filename" key leaves its PNG as an actool "unassigned child":
the icon never reaches Assets.car and altool rejects the upload with 90022/90023
(run 37085821307). So a manifest entry that resolves only by naming convention
is a failure, not a pass.
"""
import json, struct, sys, os

ICONSET = "ios/Runner/Assets.xcassets/AppIcon.appiconset"

with open(os.path.join(ICONSET, "Contents.json")) as f:
    images = json.load(f)["images"]

fail = False
assigned = set()
for entry in images:
    size = entry["size"]
    w, h = (float(x) for x in size.split("x"))
    px = w * int(entry["scale"][0])
    name = entry.get("filename")
    if not name:
        print(f"NO FILENAME: entry {entry['idiom']} {size} {entry['scale']} names no file")
        fail = True
        continue
    assigned.add(name)
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

on_disk = {f for f in os.listdir(ICONSET) if f.lower().endswith(".png")}
unassigned = on_disk - assigned
if unassigned:
    print(f"UNASSIGNED: {sorted(unassigned)} exist but no Contents.json entry names them")
    fail = True

# iPad support requires these entries to exist at all
ipad = {(e["size"], e["scale"]) for e in images if e["idiom"] == "ipad"}
need = {("76x76", "1x"), ("76x76", "2x"), ("83.5x83.5", "2x"), ("152x152", "2x"), ("167x167", "2x")}
missing = need - ipad
if missing:
    print(f"MISSING iPad ENTRIES: {sorted(missing)}")
    fail = True

sys.exit(1 if fail else 0)