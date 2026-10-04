# Sidebar LEDs

Three fixed lanes accompany each project’s monospace name and optional Git/GitHub counts. Counts use neutral ink. Folder glyphs and the host lane are omitted.

| Lane | Dark | White | Amber | Blue | Red |
| --- | --- | --- | --- | --- | --- |
| B — backup | Healthy, checking, paused, stopped, or unconfigured | Flashes during object transfer | — | — | Backup unavailable |
| Δ — differences | No known difference | Peer-only default-branch difference | This Mac’s known GitHub default-branch difference | — | — |
| T — terminal | No live terminal | Active command; pulses on live output | — | Waiting for input | — |

GitHub mismatch takes precedence over peer-only differences. It includes ahead, behind and divergence; cached tips alone do not prove an unpublished commit. Terminal output is coalesced to at most five pulses per second and replayed history does not pulse. Reduce Motion uses steady illumination. Every lane has a status tooltip.

Implementation reference: `design-explorations/sidebar-led-C.reference.html`. Data decisions: `design-explorations/sidebar-led-C.manifest.md`.
