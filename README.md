# Pixon

A fast, native photo editor and library for macOS, built with SwiftUI, Core Image and Metal.

Pixon is a non-destructive editor in the spirit of Lightroom, aimed at responsive sliders, an
uncluttered interface and quick imports. Your photos are never modified or copied: Pixon works on
them where they are and stores edits as small sidecar files next to them. The only time Pixon
touches a photo file's name is the optional rename on import, which is off by default and revertible.

> **Status:** early (v0.1). It is usable day to day, but expect rough edges and changing file
> formats. Keep backups of photos you care about, as you would with any editor.

## Features

- **Import in place.** Add folders (optionally with subfolders) without copying anything. Skip
  duplicates by content, apply a preset, rename files with a pattern (revertible) and file the
  import into a collection. Imported folders are watched for new files, and moved folders can be
  relocated.
- **Library.** Sidebar with All photos, Last import, Folders and manual Collections. Thumbnail grid,
  star ratings, pick/reject flags, filters, multi-select and drag to collections.
- **Quick and Detailed editing.** Quick has the everyday sliders. Detailed adds full light and color,
  color grading wheels, tone curve, HSL and detail.
- **Masks.** Brush, linear, radial, subject (Apple Vision) and sky masks, each with its own sliders.
  Combine several gradients (add, subtract, intersect), pick individual subjects, grow, shrink and
  soften automatic masks, and refine any mask with brush strokes.
- **Crop and straighten** with aspect presets.
- **Edit history.** Every edit is a named step you can return to, plus named snapshots. Saved per photo.
- **Presets, copy/paste settings, undo/redo.**
- **Export** to JPEG, HEIC or 16-bit TIFF.
- **RAW support** through Core Image: whatever macOS can decode (DNG, CR2/CR3, NEF, ARW, RAF, ORF and more).
  JPEG, PNG, HEIC, TIFF, WebP and AVIF are supported too.
- **Safe deleting.** Photos are moved to the macOS Trash, never erased.

## Requirements

- macOS 14 (Sonoma) or later. Apple Silicon is recommended for editing large RAW files.
- To build from source: the Swift 6 toolchain. Xcode 16 or later, or just the Xcode command line
  tools (`xcode-select --install`), is enough. Full Xcode is not required.

## Install

Pixon is distributed as source. Build it yourself in a minute:

```bash
git clone https://github.com/napalmj/pixon.git pixon
cd pixon
./scripts/bundle.sh
```

This builds a release binary and wraps it in `build/Pixon.app`. Run it with:

```bash
open build/Pixon.app
```

To keep it, drag `build/Pixon.app` into `/Applications`.

The app is ad-hoc signed, not notarized. An app you build yourself opens normally. If you copy the
`.app` to another Mac and macOS refuses to open it, right-click it, choose **Open**, then confirm.

A debug build (faster to compile, much slower to run) is available with `./scripts/bundle.sh debug`.

## Quick start

1. Open Pixon and press **⌘I** (or drop a folder onto the window) to import a folder of photos.
2. Rate and flag in the library with **1–5**, **P** (pick) and **X** (reject). Arrow keys move around.
3. Press **E** or **Return** to edit a photo. Use the **Quick** tab, press **D** for **Detailed**.
4. Press **\\** to compare before and after. Press **C** for crop, **O** to show a mask overlay.
5. Press **⇧⌘E** to export. Edits save automatically (**⌘S** saves immediately).

Press **⌘?** (Help ▸ Pixon Help) for a searchable list of every shortcut. More detail is in the
[user guide](docs/USER-GUIDE.md).

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| ← → (↑ ↓ in grid) | Previous / next photo |
| 0–5 | Rate |
| P / X / U | Pick / reject / unflag |
| G / E | Library / edit |
| C or R | Crop |
| \\ | Before / after |
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

## Where your data lives

| What | Where |
| --- | --- |
| Your photos | Wherever they already are. Pixon never copies them or changes their contents (export writes new files). |
| Edits, ratings, flags, history | `<photo folder>/.pixon/<filename>.json` plus `<filename>.history.json`, small JSON sidecars per photo |
| Library index (folders, collections) | `~/Library/Application Support/Pixon/catalog.json` |
| Presets | `~/Library/Application Support/Pixon/presets.json` |

To back up your work, back up your photo folders (hidden `.pixon` folders included) and the
`Pixon` folder in Application Support. Nothing is uploaded anywhere; Pixon makes no network requests.

## Development

The project is a Swift package with a single executable target and no third-party dependencies.

```bash
swift build                 # debug build
./scripts/bundle.sh         # release build wrapped in build/Pixon.app
```

Pixon has built-in command line checks, run through the built app bundle:

```bash
# Pipeline and library assertions. Prints EVERYTHING PASSED and exits 0 on success.
build/Pixon.app/Contents/MacOS/Pixon --selftest /tmp/pixon-test

# Write synthetic sample photos to try the app with.
build/Pixon.app/Contents/MacOS/Pixon --make-samples /tmp/pixon-samples

# Time a live-preview frame while a control is dragged.
build/Pixon.app/Contents/MacOS/Pixon --bench /tmp/pixon-bench [--file photo.jpg]

# Capture window snapshots of the main UI states against a throwaway catalog.
build/Pixon.app/Contents/MacOS/Pixon --snapshot /tmp/pixon-snap --catalog /tmp/snap-catalog.json --samples /tmp/pixon-samples
```

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code is organized and
[CONTRIBUTING.md](CONTRIBUTING.md) for how to send changes.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and note the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues: see
[SECURITY.md](SECURITY.md).

## License

Pixon is released under the [MIT License](LICENSE).
