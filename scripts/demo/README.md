# Portal film assets

These helpers stage a sample project inside the real Portal terminal. The Orbit
output is scripted demonstration data, not Portal build or benchmark results.

- `scene.py`: ten short ANSI output scenes. Define a shell function named `orbit`
  that invokes this script, then execute each scene as a separate command.
- `backdrop.swift`: animated native scenery. Its optional argument is the Portal
  window ID; it orders its own window immediately beneath that window.
- `record.swift`: a 60 fps ScreenCaptureKit recorder. Arguments are an unused
  output `.mov` path and duration in seconds. It captures only the staged
  `dev.mxcl.portal.film` terminal and the backdrop, excluding other applications.
  Requires macOS 15+, screen recording access, and the calibrated 1512×982 display.

Compile the Swift files with `swiftc`. Keep executables and video output outside
this repository. The filming copy uses the installed Portal executable, a distinct
bundle identifier, and the normal Developer ID signing identity. Preserve the
original signed helper bundles when preparing it.

Prepare an isolated shell, change to the sample project folder, and use **Edit →
Clear Terminal**. This leaves a blank blinking input with no session listings.

Suggested command starts (seconds): explore 2, graph 4.5, check 6.5, build 8.5,
test 12, bench 14, diff 16, assets 18, status 20, preview 22. Hold the final frame
through 30 seconds. Inspect the recorded video for actual backdrop transmission;
an offscreen capture may flatten the window's material even when the scenery is
present in the composition.
