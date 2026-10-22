# iPhone import

The iPhone UI, transcript parser, command lifecycle, and synchronizable Keychain
identity were imported from `mxcl/portal-tty` at
`731576f35e5fd9c4b301618c570ac672faf144f6` under the repository’s MIT license.

Relay networking, relay encryption, the remote agent, StoreKit, subscriptions,
and the paywall are excluded. SSH uses the session helper shipped by this
repository. The iPhone package is separate from the Mac package so its build
does not pull in macOS-only targets.
