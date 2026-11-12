# Pixon user guide

This guide walks through a typical session. For installation see the [README](../README.md). Inside
the app, **Help ▸ Pixon Help (⌘?)** has a searchable list of every shortcut.

## Importing photos

Choose **File ▸ Import Photos… (⌘I)**, or drop a folder onto the window.

Pixon works on photos **where they are**. Nothing is copied. It remembers the folder and picks up new
files added to it later. The import sheet offers:

| Option | What it does |
| --- | --- |
| Include subfolders | Also imports photos in folders inside the one you chose |
| Skip duplicates | Skips files whose content is already in your library, even under another name |
| Apply preset | Applies one of your saved presets to every imported photo |
| Rename files | Renames the original files on disk with a pattern (date-sequence, custom name-sequence, or date plus original name). Off by default. Revert it from **Last import** |
| Add to collection | Files the imported photos into a collection |

If you move an imported folder, right-click it in the sidebar and choose **Locate folder…** to point
Pixon at the new place. Your edits come along because they are stored next to the photos.

## The library

The sidebar lists **All photos**, **Last import**, your **Folders** and your **Collections**.

- **Rate** with **1–5** (press the same number again to clear, **0** clears). **Pick** with **P**,
  **reject** with **X**, **unflag** with **U**.
- **Select** several photos with ⇧-click (range) or ⌘-click (add). Most actions, such as paste
  settings or move to Trash, apply to the whole selection.
- **Filter** by flag (All, Picks, Unflagged, Rejected) and by edited or unedited from the filter menu.
- **Collections** are manual groups of photos. Create one in the sidebar, then drag photos onto it, or
  make it the target and press **B** to add the selection. A photo can be in many collections, and
  removing it from one (Delete while viewing the collection) does not delete the file.

## Editing

Press **E** or **Return** on a photo. Use ← → to move to the next photo and **G** to return to the library.

- **Quick** tab: exposure, contrast, highlights, shadows, temperature, saturation, vignette.
- **Detailed** tab (press **D** to switch): full light and color, color grading wheels, tone curve,
  HSL and detail (sharpening, noise reduction).
- **Double-click** any slider to reset it. Hold **⌥** while dragging for fine control.
- **\\** shows the original for comparison.
- **Crop and straighten**: press **C** (or **R**). **Esc** leaves the tool.

### Masks

Masks apply adjustments to part of the photo, each with its own sliders.

- **Brush**: paint where the effect applies. **[** and **]** change the brush size, **⌥-drag** erases.
- **Linear** and **radial**: drag on the photo, then use the handles to move, resize or feather.
  **⇧-drag** adds another shape to the same mask, and each shape can add, subtract or intersect.
- **Subject** (Apple Vision) and **sky**: detected automatically. For subject masks, click the
  subjects on the photo to include or leave them out. Grow, shrink and soften the result as needed.
- Any mask can be **refined** with add or subtract brush strokes.
- **O** shows or hides the red overlay that displays the mask.

### History and snapshots

The panel on the left of the editor lists every edit as a named step. Click a step to go back to it.
Your next edit removes the struck-out steps after it. **⌘Z** and **⇧⌘Z** undo and redo one step at a
time. **Snapshots ▸ Save** keeps a named version that survives trimming and clearing.

### Presets and copying settings

- **Photo ▸ Save Preset…** stores the current global look. Presets carry only the global look, never
  crop or masks.
- **⇧⌘C** copies a photo's settings and **⇧⌘V** pastes them onto the selected photos. Each photo keeps
  its own crop.
- **⇧⌘R** resets all adjustments on the photo.

Edits save automatically a moment after each change (the top bar shows Saving… and Saved). **⌘S**
saves immediately.

## Exporting

Press **⇧⌘E** (**File ▸ Export…**) to write edited copies of the selected photos as **JPEG**, **HEIC**
or **16-bit TIFF**. JPEG and HEIC have a quality slider. Your originals are never changed.

## Deleting

**⌘⌫** (or **Delete** in the library grid, outside a collection) and **Photo ▸ Delete Rejected
Photos…** move photos and their edits to the macOS Trash after asking. Pixon never erases files
itself. To restore a photo, use Finder's **Put Back**, and put back the matching `.json` file from
the `.pixon` folder too if you want to keep its edits.

## Where Pixon keeps things

- Edits, ratings and flags: `<photo folder>/.pixon/<filename>.json`; edit history: `<filename>.history.json` next to it
- Library index (folders, collections): `~/Library/Application Support/Pixon/catalog.json`
- Presets: `~/Library/Application Support/Pixon/presets.json`

To back up your work, include the hidden `.pixon` folders with your photos, and the `Pixon` folder in
Application Support. To move your library to another Mac, copy the photo folders (with `.pixon`) and
the `Pixon` support folder, and use **Locate folder…** in the sidebar if the folders end up in different places.

## Troubleshooting

**The app won't open on another Mac.** The build is ad-hoc signed and not notarized. Right-click the
app, choose **Open**, then confirm. Builds made on the same Mac open normally.

**A RAW file won't open or looks wrong.** Pixon decodes RAW through macOS, so a camera must be supported
by your version of macOS. Update macOS, or check that Preview can open the file.

**Sliders feel slow on large files.** Use a release build (`./scripts/bundle.sh`, not `debug`). Preview
speed also depends on the size of the photo and the GPU; see the performance notes in
[HANDOFF-ux-performance.md](HANDOFF-ux-performance.md).

**My library list is empty after an update.** If Pixon cannot read `catalog.json` it copies the file to
`catalog.unreadable-<timestamp>.json` in the same folder instead of overwriting it. Your photos and
their `.pixon` sidecars are untouched, so you can re-import the folders, or attach that file to a bug report.

**Reporting a problem.** Please open an issue with your macOS version, Mac model, the photo's file
type, and the steps to reproduce. See [CONTRIBUTING.md](../CONTRIBUTING.md).
