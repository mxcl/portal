# CodeEditSourceEditor

Vendored from [CodeEditSourceEditor 0.15.2](https://github.com/CodeEditApp/CodeEditSourceEditor/tree/0.15.2),
commit `424453d2232c9912933a3b5a1f3d3df669404ed0` (MIT).

Local changes: remove the unused CodeEditSymbols import and dependency. Its
asset catalog requires Xcode and breaks this project's command-line SwiftPM build.
The manifest includes runtime dependencies only; upstream lint plugins and test
infrastructure are omitted. CodeEditLanguages uses the sibling vendored package for resource lookup fixes.
Markdown captures receive theme colors and font traits. Injection language lookup accepts
grammar names and file extensions, and inline Markdown preserves block heading highlights.

CodeEditTextView uses the sibling vendored package to fix horizontal scrolling.
