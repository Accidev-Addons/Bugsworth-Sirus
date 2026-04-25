# Changelog

All notable changes to Bugsworth will be documented in this file.

## [2.0.2] — 2026-03-18

### Fixed
- **Viewer: Copy All highlight lingers** — text selection now auto-clears after the "Press Ctrl+C" flash fades out

### Added
- **Viewer: Clear All button** — one-click wipe of all captured errors, directly in the viewer toolbar

## [2.0.1] — 2026-03-18

### Fixed
- **Viewer: Copy All crash** — `copyFlash` was a FontString (no `SetScript` support); changed to a Frame wrapping a FontString so the fade-out animation works
- **Viewer: sidebar frame leak** — nav entries were creating new frames every rebuild and just hiding old ones, causing unbounded frame accumulation. Replaced with a proper frame pool (`acquireNavFrame`/`releaseAllNavFrames`) that reuses frames with `ClearAllPoints()` on each cycle
- **Viewer: accordion arrow glyphs** — replaced UTF-8 triangle characters (▼/▶) with ASCII equivalents (`v`/`>`) since WoW 3.3.5a's default font can't render them
