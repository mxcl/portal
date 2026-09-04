Vendored from tornikegomareli/gitdiff 0.1.0 (114b571a6dd0660ec9a57ba58a897964020f6bc2).

Local patch: size line-number gutters per file using intrinsic digit widths and
prevent wrapping. Upstream uses fixed 20-point dual columns.

Check: `swift test --package-path vendor/gitdiff`
