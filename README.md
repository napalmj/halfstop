# Pixon

A fast photo editor for macOS (SwiftUI + Core Image + Metal).
Import references photos where they already are (nothing is copied). Edits,
ratings and flags are saved as small JSON sidecars in a hidden `.pixon/` folder
next to your photos; the library index (folders, collections) lives in
`~/Library/Application Support/Pixon/catalog.json`.

## Build & run

```bash
./scripts/bundle.sh          # builds build/Pixon.app (release)
open build/Pixon.app
```

Requires macOS 14+ and the Xcode command line tools.

## Features

- **Import**: add folders in place (optionally with subfolders); skip duplicates by content,
  apply a preset, rename files with a pattern (revertible), file into a collection.
  Imported folders are watched for new files; moved folders can be relocated.
- **Library**: sidebar with All photos, Last import, Folders and manual Collections;
  thumbnail grid, ratings, pick/reject flags, filters, multi-select, drag to collections.
- **Deleting**: Move to Trash (⌘⌫, or Delete in the grid) and Delete Rejected Photos (Photo or
  filter menu) move the files and their edits to the macOS Trash after a warning; Finder's
  Put Back restores them (put back the matching `.json` too to keep the edits). Help ▸ Pixon
  Help (⌘?) lists every shortcut.
- **Quick tab**: exposure, contrast, highlights, shadows, temperature, saturation, vignette.
- **Detailed tab**: full light & color, color grading wheels, tone curve, HSL, detail.
- **Masks**: brush, linear, radial, subject (Apple Vision) and sky; each with its own sliders.
  A mask can combine several linear/radial gradients (add, subtract, intersect; ⇧-drag adds one).
  Subject masks let you pick individual subjects (click them on the photo), and automatic
  masks can grow/shrink and soften. Any mask can be refined with add/subtract brush strokes.
- **Crop & straighten** with aspect presets.
- **Edit history** (left of the editor): every edit is a named step; click one to go back, and
  editing from there trims the later steps. Snapshots save named versions. Saved per photo.
- **Saving** is automatic (the top bar shows Saving…/Saved); ⌘S writes immediately.
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
| ⌘I | Import photos |
| B | Add selection to the target collection |
| Delete | In a collection: remove from it. Elsewhere in the grid: move to Trash (asks first) |
| ⌘⌫ | Move selected photos to Trash (asks first) |
| ⇧⌘S | Show / hide the sidebar (library) or history (editor) |
| ⌘S | Save now |

## Developer checks

```bash
build/Pixon.app/Contents/MacOS/Pixon --selftest /tmp/pixon-test      # pipeline assertions
build/Pixon.app/Contents/MacOS/Pixon --make-samples /tmp/pixon-samples
build/Pixon.app/Contents/MacOS/Pixon --snapshot /tmp/pixon-snap --catalog /tmp/snap-catalog.json --samples /tmp/pixon-samples
```
