#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True
import datetime
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("push", Path(__file__).with_name("prepare-push-signing.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
profile = {"Entitlements": {
    "com.apple.application-identifier": "TEAM.dev.mxcl.portal.menu-helper",
    "com.apple.developer.team-identifier": "TEAM",
    "com.apple.developer.aps-environment": "production",
}, "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)}
assert module.entitlements(profile) == profile["Entitlements"]
for key, value in [("com.apple.application-identifier", "TEAM.wrong"),
                   ("com.apple.developer.aps-environment", "wrong")]:
    invalid = {**profile, "Entitlements": {**profile["Entitlements"], key: value}}
    try:
        module.entitlements(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid profile accepted")
try:
    module.entitlements({**profile, "ExpirationDate": datetime.datetime(2000, 1, 1)})
except ValueError:
    pass
else:
    raise AssertionError("Expired profile accepted")
print("Push signing checks passed")
