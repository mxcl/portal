#!/usr/bin/env python3
"""Validate the Mac profile before granting access to Portal's existing Keychain group."""
import datetime
import plistlib
import sys

with open(sys.argv[1], 'rb') as file:
    profile = plistlib.load(file)
identifier = 'ZU76A67LGU.dev.mxcl.portal'
allowed = profile['Entitlements']
if allowed.get('com.apple.application-identifier') != identifier:
    raise SystemExit('The discovery profile must belong to dev.mxcl.portal.')
if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit('The discovery provisioning profile has expired.')
if not any(identifier == group or (group.endswith('.*') and identifier.startswith(group[:-1]))
           for group in allowed.get('keychain-access-groups', [])):
    raise SystemExit('The profile does not permit Portal Keychain access.')
with open(sys.argv[2], 'wb') as file:
    plistlib.dump({'com.apple.application-identifier': identifier,
                  'com.apple.developer.team-identifier': 'ZU76A67LGU',
                  'keychain-access-groups': [identifier]}, file)
