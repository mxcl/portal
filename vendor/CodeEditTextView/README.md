# CodeEditTextView

Vendored from [CodeEditTextView 0.12.1](https://github.com/CodeEditApp/CodeEditTextView/tree/0.12.1),
commit `d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec` (MIT).

Local changes: remove the local variable shadowing the `inout` maximum line width
in `TextLayoutManager.layoutLine`. The caller must receive the measured width so
unwrapped documents grow and allow horizontal scrolling.

The manifest includes runtime dependencies only; upstream lint plugins and test
infrastructure are omitted. The regression test is in `GitSyncAppTests`.
