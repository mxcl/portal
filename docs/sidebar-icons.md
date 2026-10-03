# Sidebar status icons

Generated with the built-in imagegen tool, then cropped to the visible alpha bounds and resized to 64 pixels. SwiftUI renders them as 12-point template images so the app controls their color.

Assets: `Sources/PortalApp/Resources/sidebar-branch-difference.png`, `sidebar-terminal.png`, and `sidebar-backup.png`.

Each prompt used this text, substituting the asset name and subject below:

> Create a single small monochrome UI status icon for a macOS sidebar, asset {name}. {subject}. Flat crisp solid black silhouette and simple strokes, centered, generous transparent padding, no text or gradients, recognizable at 12 pixels. Transparent background.

| Name | Subject |
| --- | --- |
| branch-difference | A git branch with two diverging tips |
| terminal | A terminal window with a > prompt |
| backup | An external backup drive with a small checkmark |
