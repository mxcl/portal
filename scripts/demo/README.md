# Portal film assets

The film uses real Portal views, the default appearance, and a blank blinking
prompt. Orbit's ANSI output is scripted demonstration data, not Portal build or
benchmark results.

Build `PortalFilm` with `swift build -c release --product PortalFilm`. Prepare a
separate app bundle from the installed Portal app, replace its main executable
with that binary, and give it a distinct bundle identifier. Sign the outer bundle
with the normal Developer ID identity; preserve the original signed helpers.
Compile `backdrop.swift` and `record.swift` with `swiftc` into a tools directory.
Keep executables and recordings outside this repository.

Run the filming bundle's executable with three arguments:

```
PortalTerminalApp <repository> <tools-directory> <unused-output.mov>
```

`Film.swift` types through the editor's native text-input methods. No desktop
controller or synthetic mouse events are involved. Commands start at 2, 6, 10,
14, 19, 23, 27, 31, 35, and 39 seconds. Typing takes roughly 100 ms per character,
with a pause before submission. Capture lasts 46 seconds, including a final hold.

The backdrop gradually cycles through blue, jade, amber, and violet over 48 seconds.
Its diffuse pools, caustic highlights, and dark ground share the same color timeline.

The backdrop uses ordinary window ordering and exits when the filming host exits,
even if the host is killed. The harness also terminates child processes on errors
and successful completion. Set `PORTAL_FILM_VALIDATE_ONLY=1` to exercise the
commands quickly without any backdrop or recording, logging scroll geometry.

The recorder uses full-display ScreenCaptureKit capture to preserve native
behind-window blur; capturing only selected windows flattens it. Keep the filmed
window visible throughout the take. Cursor capture is disabled. Recording requires
macOS 15+, screen recording access, and the calibrated 1512×982 display. The output
is silent. Inspect the first frame, typed text, and final output before exporting.

`scene.py` supplies the ten scenes. `perform.py` is the older session-bridge runner;
its fixtures can be checked with `python3 scripts/demo/perform.py --self-test`.
