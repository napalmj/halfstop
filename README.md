# Pixon

A fast, folder-based photo editor for macOS (SwiftUI + Core Image + Metal).
No import, no catalog: open a folder and go. Edits, ratings and flags are saved
as small JSON sidecars in a hidden `.pixon/` folder next to your photos.

## Build & run

```bash
./scripts/bundle.sh          # builds build/Pixon.app (release)
open build/Pixon.app
```

Requires macOS 14+ and the Xcode command line tools.

## Features

- **Library**: thumbnail grid, ratings, pick/reject flags, filters, multi-select.
- **Quick tab**: exposure, contrast, highlights, shadows, temperature, saturation, vignette.
- **Detailed tab**: full light & color, color grading wheels, tone curve, HSL, detail.
- **Masks**: brush, linear, radial, subject (Apple Vision) and sky; each with its own sliders.
- **Crop & straighten** with aspect presets.
- **Presets, copy/paste settings, undo/redo, export** (JPEG / HEIC / 16-bit TIFF).
- RAW support via Core Image (whatever macOS can decode: CR3, NEF, ARW, DNG, RAF, …).

## Keys

| Key | Action |
| --- | --- |
| ← → (↑ ↓ in grid) | Previous / next photo |
| 0–5 | Rate |
| P / X / U | Pick / reject / unflag |
| G / E | Library / edit |
| C or R | Crop |
| \ | Before / after |
| D | Toggle Quick / Detailed |
| O | Mask overlay |
| [ ] | Brush size (⌥ while painting erases) |
| Esc | Leave crop / mask / back to library |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⇧⌘C / ⇧⌘V | Copy / paste settings |
| ⇧⌘E | Export |

## Developer checks

```bash
build/Pixon.app/Contents/MacOS/Pixon --selftest /tmp/pixon-test      # pipeline assertions
build/Pixon.app/Contents/MacOS/Pixon --make-samples /tmp/pixon-samples
build/Pixon.app/Contents/MacOS/Pixon --snapshot /tmp/pixon-snap      # scripted UI captures
```
