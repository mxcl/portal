#!/usr/bin/env python3
"""Prepare the helper's APNs entitlements from a decoded provisioning profile."""
import datetime
import plistlib
import sys
from pathlib import Path


def entitlements(profile):
    values = profile["Entitlements"]
    app_id = values.get("com.apple.application-identifier", "")
    team = values.get("com.apple.developer.team-identifier", "")
    if not team or app_id != team + ".dev.mxcl.git-sync.menu-helper":
        raise ValueError("Profile must match dev.mxcl.git-sync.menu-helper and its team")
    environment = values.get("com.apple.developer.aps-environment")
    if environment not in ("development", "production"):
        raise ValueError("Profile must enable macOS Push Notifications")
    expiry = profile.get("ExpirationDate")
    if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("Provisioning profile has expired")
    return {key: values[key] for key in (
        "com.apple.application-identifier", "com.apple.developer.team-identifier",
        "com.apple.developer.aps-environment",
    )}


if __name__ == "__main__":
    profile, output, info_path = map(Path, sys.argv[1:])
    values = entitlements(plistlib.loads(profile.read_bytes()))
    output.write_bytes(plistlib.dumps(values))
    info = plistlib.loads(info_path.read_bytes())
    info["GitinuumAPNSEnvironment"] = "sandbox" if values["com.apple.developer.aps-environment"] == "development" else "production"
    info_path.write_bytes(plistlib.dumps(info))
