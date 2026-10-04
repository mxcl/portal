# Sidebar LED fixture manifest

Source: user's Portal appshot from October 3, 2026; 17 active projects. Same fixtures in all three variants. The mock is an HTML comparison, not a change to the live SwiftUI app.

| Element | Source / field | Class | Count |
| --- | --- | --- | --- |
| Project names | appshot sidebar rows / configuration.folders.name | Real | 17/17 |
| Git additions/deletions | workingChangeCounts(for:) | Sometimes | 2/17 shown |
| GitHub stars | githubCounts(for:).stars | Sometimes | 6/17 nonzero |
| GitHub open PRs | githubCounts(for:).pullRequests | Sometimes | 1/17 nonzero |
| GitHub open issues | githubCounts(for:).issues | Sometimes | 1/17 nonzero |
| Backup current | backupSidebarStatus(for:) | Real | 13/17 |
| Backup checking | backupSidebarStatus(for:) | Real | 4/17 |
| Branch differences | hasBranchDifferences(for:) | Real | 3/17 |
| Orange branch classification | ahead versus behind needed to refine current tip inequality | Aspirational refinement | 3/17 uncertain classification |
| Remote-only | configuration.folders.availableLocally / globe in appshot | Real | 4/17 |
| Terminal running / finished | terminals.projectActivities | Simulated existing capability | 2/17 examples; not observed in screenshot |
| Red error state | backup/helper error state | Available, not illustrated | 0/17 |
| Lane labels and fixed LED positions | New presentation | Design | 4 lanes |

No merge, fetch, push, backup, or terminal behavior changes are proposed. LEDs are presentation of existing state. Width and row-height sliders are exploration tools, not proposed product UI.
