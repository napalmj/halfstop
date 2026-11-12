# Architecture

A short map of the code for people who want to read or change it. Pixon is a Swift package with one
executable target (`Sources/Pixon`), no third-party dependencies, and a SwiftUI interface over a Core
Image / Metal pipeline.

## Source layout

| Folder | Contents |
| --- | --- |
| `App/` | App entry point and menu commands (`PixonApp.swift`), the in-app Help window (`HelpView.swift`), and the headless command line modes: `SelfTest.swift` (`--selftest`, `--make-samples`, `--snapshot`) and `Bench.swift` (`--bench`) |
| `Model/` | Plain data types: `Adjustments` (every slider, curve, HSL value, crop and mask), `Photo` (per-photo sidecar, flags, ratings, history steps, supported file extensions), `Catalog` (the library index, folder watching) and `HistoryLabel` (names edit history steps) |
| `Library/` | `LibraryStore` (the central observable state: selection, filters, edits, saving, undo, trash), the import scan and options (`Importer.swift`, `ImportSheet.swift`), the sidebar, and the library grid and export UI |
| `Editor/` | The editing screen: `EditorView` and the preview area, `AdjustPanel` (sliders and mask controls), `PreviewRenderer` (Metal preview view), `CropOverlay` and `HistoryPanel` |
| `Rendering/` | The develop pipeline: `ImageSource` (decodes RAW and raster files, builds the Core Image filter graph), `ColorLUT` (bakes tone and color adjustments into one 3D lookup table), `MaskRenderer` (turns mask descriptions into grayscale images), and `RenderServices` (thumbnails, histogram, export) |
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

Pixon never writes to the photo files themselves.

- **Sidecars:** `<folder>/.pixon/<filename>.json` holds a photo's `Adjustments`, rating, flag and edit
  history. Decoding is tolerant, so older sidecars still load when new fields are added. Keep it that way
  when you add settings: give new fields defaults.
- **Catalog:** `~/Library/Application Support/Pixon/catalog.json` lists imported folders and
  collections. A photo is identified by `PhotoRef` (folder identity plus relative path), so moving a
  folder only changes the folder's stored path. An unreadable catalog is copied aside rather than
  overwritten.
- **Presets:** `~/Library/Application Support/Pixon/presets.json`.
- Folder watching ignores `.pixon/`, so saving edits does not trigger rescans.

## Testing

There is no XCTest target. The app checks itself:

```bash
./scripts/bundle.sh
build/Pixon.app/Contents/MacOS/Pixon --selftest /tmp/pixon-test
```

`--selftest` runs pipeline assertions (`SelfTest.run`) and library tests (`LibraryTest`) and prints
`EVERYTHING PASSED` with exit code 0 on success. When you change the develop pipeline or the library
model, add a case there. `--bench` measures per-frame cost and is useful for performance work.

## Keeping things in step

- Shortcuts live in `KeyHandler` and `PixonCommands`. The Help window (`HelpView.swift`) and the
  shortcut table in the README must match them.
- Supported file types are listed in `Model/Photo.swift` (`ImageFormats`).

For performance and usability plans see [HANDOFF-ux-performance.md](HANDOFF-ux-performance.md).
