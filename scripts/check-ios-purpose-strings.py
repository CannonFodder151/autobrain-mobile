#!/usr/bin/env python3
"""Verify ios/Runner/Info.plist carries a user-facing purpose string for every
protected-resource API this app links (AUT-5322).

geolocator's iOS implementation references
CLLocationManager.requestAlwaysAuthorization, so the uploaded binary
contains the selector and App Store Connect's pre-submission check
rejects the build with 90683 ("Missing purpose string in Info.plist")
whenever NSLocationAlwaysAndWhenInUseUsageDescription is absent —
even though the app only ever requests when-in-use authorization.
The check runs after the signed archive, so a missing key costs a
full build/upload cycle to find.
"""
import plistlib, sys

PLIST = "ios/Runner/Info.plist"

REQUIRED = (
    "NSBluetoothAlwaysUsageDescription",
    "NSCameraUsageDescription",
    "NSLocationAlwaysAndWhenInUseUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSPhotoLibraryUsageDescription",
)

with open(PLIST, "rb") as fh:
    plist = plistlib.load(fh)

fail = False
for key in REQUIRED:
    if key not in plist:
        print(f"MISSING: {key} in {PLIST} (App Store Connect 90683)")
        fail = True
        continue
    value = plist[key]
    if not isinstance(value, str) or not value.strip():
        print(f"EMPTY: {key} is {value!r}, expected a user-facing purpose string")
        fail = True
    else:
        print(f"ok: {key}")

sys.exit(1 if fail else 0)
