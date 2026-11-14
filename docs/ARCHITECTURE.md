# Architecture

A short map of the code for people who want to read or change it. Halfstop is a Swift package with one
executable target (`Sources/Halfstop`), no third-party dependencies, and a SwiftUI interface over a Core
Image / Metal pipeline.

## Source layout

| Folder | Contents |
| --- | --- |
| `App/` | The executable's entry point (`HalfstopMain`: the `halfstop` commands or the app) and the app with its menu commands (`HalfstopApp.swift`), the in-app Help window (`HelpView.swift`), the Settings window (`SettingsView.swift`), and the headless test modes: `SelfTest.swift` (`--selftest`, `--make-samples`, `--snapshot`), `CommandLineSelfTest.swift` (the command-line tool and keeping the app in step) and `Bench.swift` (`--bench`, preview frames and auto adjustments) |
| `Model/` | Plain data types: `Adjustments` (every slider, curve, HSL value, crop and mask), `Photo` (per-photo sidecar, flags, ratings, history steps, supported file extensions), `SidecarFiles` (reading and writing sidecars), `SidecarSync` (the per-folder sidecar lock, file revisions, changes made outside the app, the merge rule and keeping fields from newer versions), `Catalog` (the library index, folder watching) and `HistoryLabel` (names edit history steps) |
| `Library/` | `LibraryStore` (the central observable state: selection, filters, edits, saving, undo, trash), the import scan and options (`Importer.swift`, `ImportSheet.swift`), the sidebar, and the library grid and export UI |
| `Editor/` | The editing screen: `EditorView` and the preview area, `AdjustPanel` (sliders and mask controls), `PreviewRenderer` (Metal preview view), `CropOverlay` and `HistoryPanel` |
| `Rendering/` | The develop pipeline: `ImageSource` (decodes RAW and raster files, builds the Core Image filter graph), `ColorLUT` (bakes tone and color adjustments into one 3D lookup table), `MaskRenderer` (turns mask descriptions into grayscale images), `RenderServices` (thumbnails, histogram, export), and `AutoAdjust` / `AutoEngine` (one-click auto adjustments, measured on a small decode of the photo off the main thread and cached), with `AutoVision` (faces and horizon, via Vision, with a test hook) and `AutoRefine` (face-aware exposure and skin tint, the auto-enhance second opinion, Auto straighten) and `StyleLearner` ("Learn from my edits": per-photo features and a nearest-neighbour model of what the user changes over ✦ Auto) |
| `CLI/` | The `halfstop` command-line tool: `CommandLineTool` (arguments, the commands, render output checks, the read-only learned model), `CommandLineHelp` (`--help` text), `EditFields` (the sliders that can be set from outside, validation, clamping, labels, reporting, metadata-free JPEGs) and `JSONValue` (stable `--json` output) |
| `Components/` | Reusable views: adjustment slider and `Theme`, curve editor, histogram, thumbnails |

## How a frame is produced

1. `LibraryStore` holds the current photo's `Adjustments`. Moving a slider mutates it.
2. `PreviewRenderer` owns a decoded `ImageSource` for the photo, downsampled for preview.
3. On each draw, `ImageSource.developed(...)` builds a Core Image graph from the adjustments. Most
   tone and color work is collapsed into a single lookup table by `ColorLUT`, so it costs one GPU pass
   however many sliders are used. Masks are rendered by `MaskRenderer` and used to blend local
   adjustments.
4. The result is rendered into a Metal drawable by the preview view. The histogram is computed from it.
5. Exports use their own `ImageSource` at full resolution so they never disturb the live preview.

## Storage

Halfstop never writes to the photo files themselves.

- **Sidecars:** `<folder>/.halfstop/<filename>.json` holds a photo's `Adjustments`, rating, flag and
  snapshots, written ~0.5 s after any change. The edit history is in `<filename>.history.json`, written
  only when the history changes, with each brush stroke stored once however many steps share it
  (`Model/SidecarFiles.swift`). Sidecars from before the split (history inline) still load and move their
  history out on the next save. Decoding is tolerant, so older sidecars still load when new fields are
  added. Keep it that way when you add settings: give new fields defaults.
- **Catalog:** `~/Library/Application Support/Halfstop/catalog.json` lists imported folders and
  collections, plus the samples "Learn from my edits" measured for edited photos (`styleSamples`).
  A photo is identified by `PhotoRef` (folder identity plus relative path), so moving a folder only
  changes the folder's stored path. An unreadable catalog is copied aside rather than
  overwritten.
- **Presets:** `~/Library/Application Support/Halfstop/presets.json`.
- **Writers other than the app:** the `halfstop` command writes the same sidecars (history steps it
  makes carry `"commandLine": true`). Every writer, the app included, holds the photo folder's
  sidecar lock (`flock` on its `.halfstop` folder, `SidecarLock`) while it reads and rewrites a
  photo's files, and files are written atomically. The command keeps sidecar fields it doesn't know
  (written by a newer version) when it rewrites a file (`UnknownFields`).
- Folder watching ignores `.halfstop/` for rescans, so saving edits does not trigger them. A second
  FSEvents stream with file events watches the sidecar files themselves (see below).

## Testing

There is no XCTest target. The app checks itself:

```bash
./scripts/bundle.sh
build/Halfstop.app/Contents/MacOS/Halfstop --selftest /tmp/halfstop-test
```

`--selftest` runs pipeline assertions (`SelfTest.run`) and library tests (`LibraryTest`, including
`commandLineChecks` and `syncChecks`) and prints `EVERYTHING PASSED` with exit code 0 on success.
When you change the develop pipeline or the library model, add a case there. `--bench` measures
per-frame cost and is useful for performance work. To try the command-line tool without touching
your photos, run it on copies of `--make-samples` output.

## Command-line tool

`halfstop <command> …` is the app's own executable: `HalfstopMain` runs `CommandLineTool` when the
first argument is one of its commands (or `--help`/`--version`), before anything of the app exists,
so there's no window, no Dock icon, no folder watching and no catalog loaded for writing. Users put
it on their `PATH` with a link (`~/.local/bin/halfstop`); `CommandLineTool.appBundle` finds
Halfstop.app through the link (`Bundle.main` would be the link's folder). Started through the link
with no command, it prints help rather than starting the app outside its bundle.

- **Commands:** `info`, `get`, `set`, `auto`, `straighten`, `undo`, `redo`, `render`, `help`. Each
  photo is done on its own (an error is reported and the rest carry on); exit 0, 1 (a photo failed)
  or 2 (usage, nothing done). `--json` prints one object: `{"command", "ok", "results": [{"photo",
  "ok", …}]}`.
- **Writes** go through `SidecarFiles` like the app's, holding `SidecarLock`, as one history step
  per photo per command (`commandLine: true`), trimmed and capped like the app's history. Only the
  13 sliders in `EditFields.fields` can be set; values are checked strictly (plain decimals, finite,
  each slider once), clamped to `EditLimits` and rounded. Photo files are only read; `render` refuses
  the photo itself, anything in an edits folder, links, folders, photos with edits or camera
  metadata, and other existing files without `--force`, and writes atomically.
- **Auto** uses the same `AutoEngine` (one 1024 px decode per photo serves ✦ Auto and the horizon),
  measured outside the lock and re-checked under it. "Learn from my edits" is applied when it's on
  in the app's settings: `LearnedStyle` rebuilds the model read-only from the catalog's samples and
  those photos' sidecars, skipping photos whose current step came from the command line. The catalog
  is never written.

## Keeping the app in step with other writers

The app holds edits in memory and saves a photo's sidecar about 0.5 s after a change, so it must
notice files changed by someone else and must not overwrite them.

- `SidecarSync` remembers, per photo, the revision of its files the app last read or wrote (file
  stamp plus a content hash) and those edits (the merge base). Saves (`SidecarSync.save`, in the
  background, holding the lock) first compare the files on disk with that revision: a different one
  is reported instead of overwritten. The app's own saves match it, so they're ignored.
- `FolderWatcher` has a second FSEvents stream with file events for `…/.halfstop/*.json`. Changed
  photos are checked off the main thread (`checkSidecars`); a real change goes to
  `takeExternalChange` on the main thread.
- **The rule** (`SidecarMerge`): with no changes in the app since the last read or write, the disk's
  version is taken as is (history included). Otherwise the disk's version is taken and the app's
  changes are applied on top as one new step: each setting the app changed keeps the app's value,
  the rest come from disk (rating, flag and snapshots the same way). One undo gives exactly the
  disk's version. The app's own steps since its last save are folded into that step.
- Each found change moves the photo's epoch on; saves scheduled before it are dropped, so an old
  in-memory version can never be written over the newer one. A flush on quit merges and writes in
  place. A photo whose current step came from the command line doesn't feed "Learn from my edits".

## Keeping things in step

- Shortcuts live in `KeyHandler` and `HalfstopCommands`. The Help window (`HelpView.swift`) and the
  shortcut table in the README must match them.
- Supported file types are listed in `Model/Photo.swift` (`ImageFormats`).
