# Variant C implementation

User decisions: C selected; host lane cut; healthy backups inactive; backup transfer flashes white, errors red; terminal active white with live-output pulse, waiting blue; peer differences white, GitHub differences amber. No green illumination.

| Element | Real source | Decision |
| --- | --- | --- |
| Names | configuration.folders / inventories | Keep monospace names, omit folder glyphs |
| Git and GitHub counts | workingChangeCounts, githubCounts | Keep adjacent within name readout, neutral secondary ink; omit absent counts as before |
| Backup | backupTransferring, backupError, helperError | Dark unless transferring or error; paused/stopped never flash |
| Branch differences | hasBranchDifferences, hasGitHubBranchDifferences | GitHub mismatch amber takes precedence; peer-only white; unknown/unavailable dark |
| Terminal active / waiting | live TerminalViewController tabs + command lifecycle | Derive from running command versus existing idle live tabs; exited-only dark |
| Terminal output | live session onOutput (not history replay) | Coalesce to 5 Hz; 120 ms pulse; no persistent state |
| Host availability | Previously globe / H lane | Explicitly cut per user |

Fixture population is recorded in sidebar-leds.manifest.md. Revised reference uses those 17 projects. av output and backup transfer are simulated examples, not claimed current activity.

Deliberate deviations: bank narrowed from four lanes/82px to three lanes/54px; project counts use neutral ink rather than green/red; native sidebar search and selection remain native. Rows use the C 11pt names, 9pt counts, 10×4pt segments and ~33pt row rhythm. The initial population/sparse render checks av (Git changes + GitHub counts) and git-sync (name only) at the actual 266pt sidebar width. Reduce Motion uses steady activity lights.

Mock-only footer counts and example terminal states are omitted from the live List; actual terminal state is derived, and the existing archive section/search are retained. The saved SwiftUI preview verifies loaded and sparse row proportions independently of the browser.
