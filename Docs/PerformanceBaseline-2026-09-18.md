# Align performance baseline — 2026-09-18

Reference captured before the background resource optimization work.

- Build: Release launched from Xcode with LLDB attached
- Commit: `9527fbf`
- Process: Align PID 54362
- State: application in background, camera and analysis running
- Sampling: 7 useful samples, 2 seconds apart
- CPU: 41.9% average; 36.6–44.7% range
- Memory: 479–480 MB
- Threads: 19
- Mac memory pressure context: about 7.4 GB of 8 GB used, with about 2.4–3.0 GB compressed during the sample

The post-change comparison must use a Release build, the same background state,
camera and analysis running, and the same sampling interval. A second comparison
without LLDB should be reported separately because debugger injection changes the
memory footprint.
